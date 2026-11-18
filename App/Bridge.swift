import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct BridgeFailure: LocalizedError {
    let code: Int
    let body: String
    var errorDescription: String? { "HTTP \(code): \(body)" }
}

/// A value snapshot prevents edits in Settings from redirecting an in-flight write.
struct BridgeClient {
    let baseURL: String
    let token: String
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 240
        return URLSession(configuration: config)
    }()

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                 timeout: TimeInterval = 35) async throws -> Data {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil, components.user == nil, components.password == nil,
              let suffix = URLComponents(string: path) else { throw URLError(.badURL) }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = (components.path.isEmpty ? "" : "/" + components.path) + suffix.path
        components.queryItems = suffix.queryItems
        components.fragment = nil
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw BridgeFailure(code: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

struct CommandOutput: Decodable {
    let rc: Int
    let stdout: String
    let stderr: String
}
struct BudStatus: Decodable {
    struct Battery: Decodable { let percent: Int; let state: String }
    struct Firmware: Decodable { let version: String; let build: Int }
    struct Parsed: Decodable {
        var battery: [String: Battery]?
        var software: [String: Firmware]?
        var anc: String?
        var eq: [Double]?
        var multipoint: Bool?
        var gesture_control: [String: String]?
    }
    let parsed: Parsed
    let raw: [String: CommandOutput]
    var ohd: Bool? {
        guard let result = raw["ohd"], result.rc == 0 else { return nil }
        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

enum DeviceSource: String, Codable, CaseIterable, Identifiable {
    case phone = "Phone (BLE)", ble = "Bridge BLE", classic = "Bridge Classic"
    var id: String { rawValue }
}
struct ExploreDevice: Identifiable {
    let addr: String
    let name: String
    let rssi: Int?
    let source: DeviceSource
    var id: String { source.rawValue + ":" + addr }
    var displayName: String { name.isEmpty ? "Unnamed device" : name }
}
struct ScanResponse: Decodable {
    struct Device: Decodable { let addr: String; let name: String?; let rssi: Int? }
    let devices: [Device]
}
struct GATTResponse: Decodable {
    struct Service: Decodable, Identifiable {
        let uuid: String
        let handle: Int
        let characteristics: [Characteristic]
        var id: Int { handle }
    }
    struct Characteristic: Decodable, Identifiable {
        let uuid: String
        let handle: Int
        let properties: [String]
        let description: String?
        var id: Int { handle }
    }
    let services: [Service]
}
struct TrustEntry: Decodable { let trusted: Bool; let label: String }
struct NotificationResponse: Decodable {
    struct Event: Decodable {
        let seq: Int
        let addr: String
        let char: String
        let hex: String
    }
    let notifications: [Event]
}
struct SavedAction: Codable, Identifiable {
    var id = UUID()
    let label: String
    let addr: String
    let char: String
    let hex: String
    let source: DeviceSource
    // Bleak accepts a handle as well as a UUID, avoiding duplicate-UUID ambiguity.
    var handle: Int?
    var response: Bool = true
    var localID: String?
}
struct PendingWrite: Identifiable {
    let id = UUID()
    let action: SavedAction
    let client: BridgeClient
}
