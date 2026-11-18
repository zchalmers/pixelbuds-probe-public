import SwiftUI

struct ExploreView: View {
    @ObservedObject var bridge: BridgeStore
    @ObservedObject var probe: Probe
    @State private var source = DeviceSource.phone
    @State private var selected: ExploreDevice?

    private var devices: [ExploreDevice] {
        let phone = probe.peers.map { ExploreDevice(addr: $0.id.uuidString, name: $0.name, rssi: $0.rssi, source: .phone) }
        return (phone + bridge.devices).sorted { ($0.rssi ?? -999) > ($1.rssi ?? -999) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HeaderStrip(title: "Explore Bluetooth", subtitle: "Phone: \(probe.state) • \(devices.count) devices", online: probe.scanning || bridge.scanning)
            ErrorBanner(bridge: bridge)
            if let device = selected {
                HStack {
                    Button("‹ All devices") { selected = nil }.frame(minHeight: 44)
                    Spacer()
                    Text(device.source.rawValue).font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 12)
                DeviceDetailView(device: device, bridge: bridge, probe: probe).id(device.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Scan source", selection: $source) {
                            ForEach(DeviceSource.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Button {
                            if source == .phone {
                                if probe.scanning { probe.stopScan() } else { probe.startScan() }
                            } else {
                                probe.stopScan()
                                let choice = source
                                Task { await bridge.scan(choice) }
                            }
                        } label: {
                            HStack {
                                Text(probe.scanning && source == .phone ? "Stop phone scan" : "Scan \(source.rawValue)")
                                Spacer()
                                if bridge.scanning { ProgressView() }
                            }.frame(minHeight: 44)
                        }.buttonStyle(.borderedProminent).disabled(bridge.scanning)
                        Text("Results from all sources stay in this list. Phone addresses are iOS identifiers; Classic RSSI may be unavailable.")
                            .font(.caption).foregroundStyle(.secondary)
                        if devices.isEmpty { Text("Choose a source and scan.").padding(.vertical, 20) }
                        ForEach(devices) { device in
                            Button { selected = device } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(device.displayName).font(.headline)
                                        Spacer()
                                        Text(device.rssi.map { "\($0) dBm" } ?? "RSSI —").font(.caption.monospaced())
                                    }
                                    Text(device.addr).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(device.source.rawValue).font(.caption2.bold()).padding(5)
                                        .background(Color.cyan.opacity(0.15)).clipShape(Capsule())
                                }.frame(maxWidth: .infinity, alignment: .leading).controlCard()
                            }.buttonStyle(.plain)
                        }
                        savedActions
                    }.padding(12)
                }
            }
        }.background(Color.black.opacity(0.92))
        .onDisappear { probe.stopScan() }
    }
    private var savedActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved actions by device").font(.headline)
            if bridge.actions.isEmpty { Text("Save a characteristic write in a device’s detail.").font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(Set(bridge.actions.map(\.addr))).sorted(), id: \.self) { addr in
                VStack(alignment: .leading, spacing: 6) {
                    Text(addr).font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(bridge.actions.filter { $0.addr == addr }) { action in
                        Button { Task { await bridge.run(action, probe: probe) } } label: {
                            HStack {
                                Label(action.label, systemImage: "play.fill")
                                Spacer()
                                Text(action.source.rawValue).font(.caption2)
                            }.frame(minHeight: 44)
                        }.buttonStyle(.bordered)
                    }
                }.controlCard()
            }
            if !bridge.actions.isEmpty { MonoOutput(text: bridge.output) }
        }
    }
}

struct DeviceDetailView: View {
    let device: ExploreDevice
    @ObservedObject var bridge: BridgeStore
    @ObservedObject var probe: Probe
    @Environment(\.scenePhase) private var scenePhase
    @State private var services: [GATTResponse.Service] = []
    @State private var log = ""
    @State private var loading = false
    @State private var connected = false
    @State private var subscriptions: Set<Int> = []
    @State private var sequence = 0
    @State private var api: BridgeClient?
    @State private var sessionID = UUID()
    @State private var wantsConnection = true
    @State private var pollingError = ""

    private var phoneMatches: Bool { probe.connectedAddress == device.addr }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.displayName).font(.title3.bold())
                    Text(device.addr).font(.caption.monospaced()).textSelection(.enabled)
                    Text(bridge.trust[device.addr]?.trusted == true ? "Trusted for writes" : "First write requires trust")
                        .font(.caption).foregroundStyle(.secondary)
                    if loading { ProgressView("Loading device…") }
                    HStack {
                        Button(device.source == .classic ? "Reload SDP" : "Connect / reload") { Task { await load() } }
                            .frame(minHeight: 44).buttonStyle(.borderedProminent).disabled(loading)
                        if device.source != .classic {
                            Button("Disconnect") { Task { await disconnect() } }
                                .frame(minHeight: 44).buttonStyle(.bordered)
                        }
                    }
                }.controlCard()
                if device.source == .classic {
                    Text("Classic service records").font(.headline)
                    MonoOutput(text: log)
                } else if device.source == .ble {
                    ForEach(services) { service in
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Service \(service.uuid)").font(.caption.monospaced()).textSelection(.enabled)
                            ForEach(service.characteristics) { characteristic in
                                BridgeCharacteristicView(device: device, characteristic: characteristic,
                                                         bridge: bridge, probe: probe,
                                                         subscribed: subscriptions.contains(characteristic.handle),
                                                         read: { await read(characteristic) },
                                                         notify: { await notify(characteristic) })
                            }
                        }.controlCard()
                    }
                    Text("Read / notification stream").font(.headline)
                    if !pollingError.isEmpty { Text(pollingError).font(.caption).foregroundStyle(.red) }
                    MonoOutput(text: log)
                } else {
                    if phoneMatches {
                        Text(probe.connectedName ?? "Connecting…").font(.subheadline)
                        ForEach(probe.rows) { row in
                            PhoneCharacteristicView(device: device, row: row, bridge: bridge, probe: probe)
                        }
                    } else { Text("Connect this device to inspect its GATT services.").foregroundStyle(.secondary) }
                    LogTextView(lines: probe.logLines, startID: probe.logStartID).frame(height: 300)
                }
                if device.source != .classic {
                    Text("Saved actions").font(.headline)
                    ForEach(bridge.actions.filter { $0.addr == device.addr && $0.source == device.source }) { action in
                        Button(action.label) { Task { await bridge.run(action, probe: probe) } }
                            .frame(minHeight: 44).buttonStyle(.borderedProminent)
                    }
                    MonoOutput(text: bridge.output)
                }
            }.padding(12)
        }
        .task { await load() }
        .task {
            do { try await bridge.refreshTrust(using: api ?? bridge.client) }
            catch { bridge.report(error) }
        }
        .task(id: subscriptions.isEmpty || scenePhase != .active || !connected) {
            guard !subscriptions.isEmpty, scenePhase == .active, connected else { return }
            await poll()
        }
        .onDisappear {
            // Use the original client even if Settings has since changed.
            wantsConnection = false
            sessionID = UUID()
            let snapshot = api
            if device.source == .phone, phoneMatches { probe.disconnect() }
            if device.source == .ble, let snapshot {
                Task {
                    do { _ = try await snapshot.request("/ble/disconnect", method: "POST", body: ["addr": device.addr]) }
                    catch { bridge.report(error) }
                }
            }
        }
    }
    private func append(_ text: String) {
        log += (log.isEmpty ? "" : "\n") + text
        if log.count > 100_000 { log = String(log.suffix(100_000)) }
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        wantsConnection = true
        let generation = UUID()
        sessionID = generation
        defer { loading = false }
        let snapshot = api ?? bridge.client
        api = snapshot
        do {
            switch device.source {
            case .phone:
                if !phoneMatches {
                    guard probe.connectedAddress == nil else {
                        throw BridgeFailure(code: 409, body: "Disconnect the current phone device first")
                    }
                    guard let peer = probe.peers.first(where: { $0.id.uuidString == device.addr }) else {
                        throw BridgeFailure(code: 404, body: "Scan on the phone to find this device again")
                    }
                    probe.connect(peer)
                }
            case .classic:
                let data = try await snapshot.request("/sdp/\(device.addr)", timeout: 50)
                log = String(decoding: data, as: UTF8.self)
                let result = try JSONDecoder().decode(CommandOutput.self, from: data)
                if result.rc != 0 { throw BridgeFailure(code: 502, body: result.stderr) }
            case .ble:
                _ = try await snapshot.request("/ble/connect", method: "POST", body: ["addr": device.addr])
                guard !Task.isCancelled, wantsConnection, generation == sessionID else {
                    _ = try await snapshot.request("/ble/disconnect", method: "POST", body: ["addr": device.addr]); return
                }
                connected = true
                let data = try await snapshot.request("/ble/\(device.addr)/gatt")
                services = try JSONDecoder().decode(GATTResponse.self, from: data).services
            }
        } catch { bridge.report(error); append("ERROR: \(error.localizedDescription)") }
    }
    private func disconnect() async {
        wantsConnection = false; sessionID = UUID()
        subscriptions.removeAll(); connected = false
        if device.source == .phone { if phoneMatches { probe.disconnect() }; return }
        guard let api else { return }
        do { _ = try await api.request("/ble/disconnect", method: "POST", body: ["addr": device.addr]) }
        catch { bridge.report(error) }
    }
    private func read(_ char: GATTResponse.Characteristic) async {
        guard let api else { return }
        do {
            let data = try await api.request("/ble/read", method: "POST", body: ["addr": device.addr, "char": char.handle])
            append(String(decoding: data, as: UTF8.self))
        } catch { bridge.report(error); append("ERROR: \(error.localizedDescription)") }
    }
    private func notify(_ char: GATTResponse.Characteristic) async {
        guard let api else { return }
        let enable = !subscriptions.contains(char.handle)
        do {
            let data = try await api.request("/ble/notify", method: "POST", body: ["addr": device.addr, "char": char.handle, "enable": enable])
            if enable { subscriptions.insert(char.handle) } else { subscriptions.remove(char.handle) }
            append(String(decoding: data, as: UTF8.self))
        } catch { bridge.report(error); append("ERROR: \(error.localizedDescription)") }
    }
    private func poll() async {
        guard let api else { return }
        while !Task.isCancelled {
            do {
                let data = try await api.request("/notifications?since=\(sequence)", timeout: 10)
                try Task.checkCancellation()
                let events = try JSONDecoder().decode(NotificationResponse.self, from: data).notifications
                for event in events {
                    sequence = max(sequence, event.seq)
                    if event.addr.caseInsensitiveCompare(device.addr) == .orderedSame {
                        append("#\(event.seq) \(event.char) ← \(event.hex)")
                    }
                }
                pollingError = ""
            } catch {
                if Task.isCancelled { return }
                pollingError = "Notification polling: \(error.localizedDescription)"
            }
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
        }
    }
}
