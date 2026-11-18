import SwiftUI
import CoreBluetooth

struct BridgeCharacteristicView: View {
    let device: ExploreDevice
    let characteristic: GATTResponse.Characteristic
    @ObservedObject var bridge: BridgeStore
    @ObservedObject var probe: Probe
    let subscribed: Bool
    let read: () async -> Void
    let notify: () async -> Void
    private var properties: [String] { characteristic.properties }
    private var canWrite: Bool { properties.contains("write") || properties.contains("write-without-response") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(characteristic.description ?? "Characteristic").font(.subheadline.bold())
            Text(characteristic.uuid).font(.caption.monospaced()).textSelection(.enabled)
            Text("Handle \(characteristic.handle) • " + properties.joined(separator: ", "))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack {
                if properties.contains("read") {
                    Button("Read") { Task { await read() } }.frame(minHeight: 44).buttonStyle(.bordered)
                }
                if properties.contains("notify") || properties.contains("indicate") {
                    Button(subscribed ? "Unsubscribe" : "Subscribe") { Task { await notify() } }
                        .frame(minHeight: 44).buttonStyle(.bordered)
                }
            }
            if canWrite {
                WriteComposer(device: device, characteristic: characteristic.uuid,
                              handle: characteristic.handle, response: properties.contains("write"),
                              localID: nil, bridge: bridge, probe: probe)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).controlCard()
    }
}

struct PhoneCharacteristicView: View {
    let device: ExploreDevice
    let row: CharacteristicRow
    @ObservedObject var bridge: BridgeStore
    @ObservedObject var probe: Probe
    @State private var notifying = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Service \(row.serviceUUID.uuidString)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text(row.name.isEmpty ? "Characteristic" : row.name).font(.subheadline.bold())
            Text(row.uuid.uuidString).font(.caption.monospaced()).textSelection(.enabled)
            Text(row.properties).font(.caption2.monospaced()).foregroundStyle(.secondary)
            HStack {
                if row.characteristic.properties.contains(.read) {
                    Button("Read") { probe.read(row) }.frame(minHeight: 44).buttonStyle(.bordered)
                }
                if row.characteristic.properties.contains(.notify) || row.characteristic.properties.contains(.indicate) {
                    Button(notifying ? "Unsubscribe" : "Subscribe") {
                        notifying.toggle(); probe.notify(row, enabled: notifying)
                    }.frame(minHeight: 44).buttonStyle(.bordered)
                }
            }
            if row.characteristic.properties.contains(.write) || row.characteristic.properties.contains(.writeWithoutResponse) {
                WriteComposer(device: device, characteristic: row.uuid.uuidString,
                              handle: nil, response: row.characteristic.properties.contains(.write),
                              localID: row.id, bridge: bridge, probe: probe)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).controlCard()
    }
}

struct WriteComposer: View {
    let device: ExploreDevice
    let characteristic: String
    let handle: Int?
    let response: Bool
    let localID: String?
    @ObservedObject var bridge: BridgeStore
    @ObservedObject var probe: Probe
    @State private var hex = ""
    @State private var label = ""
    @State private var saved = false
    @State private var writing = false

    private var action: SavedAction {
        SavedAction(label: label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Write \(characteristic)" : label,
                    addr: device.addr, char: characteristic, hex: hex, source: device.source,
                    handle: handle, response: response, localID: localID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Hex bytes, e.g. 01 ff", text: $hex).commandField()
            TextField("Action label", text: $label).textFieldStyle(.roundedBorder)
            HStack {
                Button(writing ? "Writing…" : "Write hex") {
                    let draft = action
                    Task {
                        writing = true
                        await bridge.run(draft, probe: probe)
                        writing = false
                    }
                }.frame(minHeight: 44).buttonStyle(.borderedProminent).disabled(writing || !BridgeStore.validHex(hex))
                Button("Save action") {
                    // ObjectIdentifier is session-specific; saved phone writes resolve UUID on reconnect.
                    var draft = action; draft.localID = nil
                    bridge.save(draft); saved = true
                }.frame(minHeight: 44).buttonStyle(.bordered).disabled(!BridgeStore.validHex(hex))
            }
            if saved { Text("Saved to this device and Explore.").font(.caption).foregroundStyle(.green) }
        }
    }
}
