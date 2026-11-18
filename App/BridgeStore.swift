import Foundation
import Combine

@MainActor
final class BridgeStore: ObservableObject {
    @Published var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: "bridgeURL") } }
    @Published var token: String { didSet { UserDefaults.standard.set(token, forKey: "bridgeToken") } }
    @Published var status: BudStatus?
    @Published var reachable = false
    @Published var error: String?
    @Published var busy = false
    @Published var scanning = false
    @Published var devices: [ExploreDevice] = []
    @Published var actions: [SavedAction] = []
    @Published var trust: [String: TrustEntry] = [:]
    @Published var pendingWrite: PendingWrite?
    @Published var output = ""
    @Published var health = "Not tested"
    @Published var anc = "off"
    @Published var eq = [Double](repeating: 0, count: 5)
    @Published var multipoint = false
    @Published var ohd = false

    var client: BridgeClient { BridgeClient(baseURL: baseURL, token: token) }

    init() {
        baseURL = UserDefaults.standard.string(forKey: "bridgeURL") ?? "http://127.0.0.1:8180"
        token = UserDefaults.standard.string(forKey: "bridgeToken") ?? ""
        if let data = UserDefaults.standard.data(forKey: "savedActions") {
            actions = (try? JSONDecoder().decode([SavedAction].self, from: data)) ?? []
        }
    }

    func report(_ failure: Error) {
        if failure is CancellationError || (failure as? URLError)?.code == .cancelled { return }
        error = failure.localizedDescription
    }

    func refresh() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        await loadStatus(using: client)
    }

    private func loadStatus(using api: BridgeClient) async {
        do {
            let data = try await api.request("/buds/status", timeout: 180)
            reachable = true
            output = String(decoding: data, as: UTF8.self)
            let value = try JSONDecoder().decode(BudStatus.self, from: data)
            status = value
            if let mode = value.parsed.anc?.lowercased(), ["off", "active", "aware", "adaptive"].contains(mode) { anc = mode }
            if let bands = value.parsed.eq, bands.count == 5 { eq = bands.map { min(6, max(-6, $0)) } }
            if let enabled = value.parsed.multipoint { multipoint = enabled }
            if let enabled = value.ohd { ohd = enabled }
            let failures = value.raw.filter { $0.value.rc != 0 }.map { "\($0.key): \($0.value.stderr)" }
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        } catch {
            reachable = false; status = nil; report(error)
        }
    }

    func command(_ args: [String]) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        let api = client
        do {
            let data = try await api.request("/buds/cmd", method: "POST", body: ["args": args], timeout: 200)
            output = String(decoding: data, as: UTF8.self)
            let result = try JSONDecoder().decode(CommandOutput.self, from: data)
            if result.rc != 0 { error = "Command exited \(result.rc): \(result.stderr)"; return }
            // Keep the command response visible verbatim while refreshing controls.
            let commandOutput = output
            await loadStatus(using: api)
            output = commandOutput
        } catch { report(error) }
    }

    func rawCommand(_ text: String) async {
        do {
            let data = Data(text.utf8)
            let args: [String]
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let list = object["args"] as? [String] {
                args = list
            } else { throw BridgeFailure(code: 400, body: "Enter {\"args\":[\"get\",\"anc\"]}") }
            guard !args.isEmpty else { throw BridgeFailure(code: 400, body: "args cannot be empty") }
            await command(args)
        } catch { report(error) }
    }

    func testConnection() async {
        do {
            let data = try await client.request("/health", timeout: 12)
            health = String(decoding: data, as: UTF8.self); reachable = true
        } catch { reachable = false; health = error.localizedDescription; report(error) }
    }

    func scan(_ source: DeviceSource) async {
        guard !scanning, source != .phone else { return }
        scanning = true; error = nil
        defer { scanning = false }
        do {
            let route = source == .ble ? "ble" : "classic"
            let data = try await client.request("/scan/\(route)?seconds=8", timeout: 40)
            let result = try JSONDecoder().decode(ScanResponse.self, from: data)
            devices.removeAll { $0.source == source }
            devices += result.devices.map { ExploreDevice(addr: $0.addr, name: $0.name ?? "", rssi: $0.rssi, source: source) }
        } catch { report(error) }
    }

    func refreshTrust(using api: BridgeClient? = nil) async throws {
        let data = try await (api ?? client).request("/trust")
        trust = try JSONDecoder().decode([String: TrustEntry].self, from: data)
    }

    func removeTrust(_ addr: String) async {
        do {
            let api = client
            _ = try await api.request("/trust/\(addr)", method: "POST", body: ["trusted": false])
            try await refreshTrust(using: api)
        } catch { report(error) }
    }

    func save(_ action: SavedAction) {
        actions.append(action); persistActions()
    }
    func clearActions() { actions.removeAll(); persistActions() }
    private func persistActions() {
        if let data = try? JSONEncoder().encode(actions) { UserDefaults.standard.set(data, forKey: "savedActions") }
    }

    func run(_ action: SavedAction, probe: Probe) async {
        error = nil
        let api = client
        do {
            guard Self.validHex(action.hex) else { throw BridgeFailure(code: 400, body: "Enter complete hex byte pairs") }
            if action.source == .phone {
                try await refreshTrust(using: api)
                guard trust[action.addr]?.trusted == true else {
                    pendingWrite = PendingWrite(action: action, client: api); return
                }
                try await probe.prepareWrite(addr: action.addr, characteristicID: action.localID ?? action.char)
                try probe.write(characteristicID: action.localID ?? action.char, hex: action.hex)
                output = "Phone write submitted: \(action.char) ← \(action.hex). See the device log for acknowledgement."
            } else if action.source == .ble {
                // Saved actions also work after the detail screen has disconnected.
                _ = try await api.request("/ble/connect", method: "POST", body: ["addr": action.addr])
                try await write(action, using: api)
            }
        } catch let failure as BridgeFailure where failure.code == 403 {
            pendingWrite = PendingWrite(action: action, client: api)
        } catch { report(error) }
    }

    func confirm(_ pending: PendingWrite, probe: Probe) async {
        pendingWrite = nil
        do {
            _ = try await pending.client.request("/trust/\(pending.action.addr)", method: "POST",
                                                 body: ["trusted": true, "label": pending.action.label])
            try await refreshTrust(using: pending.client)
            if pending.action.source == .phone {
                try await probe.prepareWrite(addr: pending.action.addr, characteristicID: pending.action.localID ?? pending.action.char)
                try probe.write(characteristicID: pending.action.localID ?? pending.action.char, hex: pending.action.hex)
                output = "Phone write submitted: \(pending.action.char) ← \(pending.action.hex). See the device log for acknowledgement."
            } else {
                // Exactly one retry. A second 403 is surfaced, never re-prompts.
                try await write(pending.action, using: pending.client)
            }
        } catch { report(error) }
    }

    private func write(_ action: SavedAction, using api: BridgeClient) async throws {
        let characteristic: Any = action.handle.map { $0 as Any } ?? action.char
        let data = try await api.request("/ble/write", method: "POST", body: [
            "addr": action.addr, "char": characteristic, "hex": action.hex, "response": action.response
        ])
        output = String(decoding: data, as: UTF8.self)
    }

    static func validHex(_ text: String) -> Bool {
        let value = text.filter { !$0.isWhitespace }
        return !value.isEmpty && value.count <= 131072 && value.count % 2 == 0 && value.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
