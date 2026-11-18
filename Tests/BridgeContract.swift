import Foundation

@main
struct BridgeContract {
    static func main() async throws {
        let api = BridgeClient(baseURL: CommandLine.arguments[1], token: "contract-token")
        let health = try await api.request("/health")
        let healthy = try JSONSerialization.jsonObject(with: health) as! [String: Bool]
        precondition(healthy["ok"] == true)
        let scanned = try await api.request("/scan/ble?seconds=8")
        let scan = try JSONDecoder().decode(ScanResponse.self, from: scanned)
        precondition(scan.devices.first?.addr == "AA:BB:CC:DD:EE:FF")
        precondition(scan.devices.first?.rssi == -60)
        let statusData = try await api.request("/buds/status")
        let status = try JSONDecoder().decode(BudStatus.self, from: statusData)
        precondition(status.parsed.battery?["left"]?.percent == 82)
        precondition(status.parsed.battery?["case"]?.state == "charging")
        precondition(status.ohd == true)
        precondition(status.parsed.eq?.count == 5)
        let gattData = try await api.request("/ble/AA:BB:CC:DD:EE:FF/gatt")
        let gatt = try JSONDecoder().decode(GATTResponse.self, from: gattData)
        precondition(gatt.services.first?.characteristics.first?.handle == 5)
        _ = try await api.request("/ble/connect", method: "POST", body: ["addr": "AA:BB:CC:DD:EE:FF"])
        do {
            _ = try await api.request("/ble/write", method: "POST", body: ["addr": "AA:BB:CC:DD:EE:FF", "char": 5, "hex": "01 ff", "response": false])
            preconditionFailure("Expected 403")
        } catch let error as BridgeFailure {
            precondition(error.code == 403 && error.body.contains("not trusted"))
        }
        let data = try await api.request("/notifications?since=4")
        let notifications = try JSONDecoder().decode(NotificationResponse.self, from: data)
        precondition(notifications.notifications.first?.seq == 5)
        let action = SavedAction(label: "Test", addr: "AA:BB:CC:DD:EE:FF", char: "abc", hex: "01", source: .ble, handle: 5, response: false)
        let decoded = try JSONDecoder().decode(SavedAction.self, from: JSONEncoder().encode(action))
        precondition(decoded.addr == action.addr && decoded.handle == 5 && !decoded.response)
        print("Bridge contract checks passed")
    }
}
