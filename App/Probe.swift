import CoreBluetooth
import Combine
import Foundation

// MARK: - small helpers

extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    var printable: String {
        String(map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}

enum Known {
    static let services: [String: String] = [
        "FE2C": "Google Fast Pair Service",
        "180F": "Battery Service",
        "180A": "Device Information",
        "109B862F-50E3-45CC-8EA1-AC62DE4846D1": "Unknown Google service (0x0f37-0x0f3e)",
        "15190001-12F4-C226-88ED-2AC5579F2A85": "Accessory Non-Owner",
    ]

    static let characteristics: [String: String] = [
        "FE2C1233-8366-4814-8EB0-01DE32100BEA": "Model ID",
        "FE2C1234-8366-4814-8EB0-01DE32100BEA": "Key-based Pairing",
        "FE2C1235-8366-4814-8EB0-01DE32100BEA": "Passkey",
        "FE2C1236-8366-4814-8EB0-01DE32100BEA": "Account Key",
        "FE2C1237-8366-4814-8EB0-01DE32100BEA": "Additional Data",
        "FE2C1238-8366-4814-8EB0-01DE32100BEA": "Beacon / Find Hub actions",
        "FE2C1239-8366-4814-8EB0-01DE32100BEA": "Message Stream PSM",
        "2A19": "Battery Level",
        "2A24": "Model Number",
        "2A25": "Serial Number",
        "2A26": "Firmware Revision",
        "2A27": "Hardware Revision",
        "2A29": "Manufacturer Name",
    ]

    static func serviceName(_ uuid: CBUUID) -> String {
        services[uuid.uuidString] ?? services[uuid.uuidString.uppercased()] ?? ""
    }

    static func characteristicName(_ uuid: CBUUID) -> String {
        let key = uuid.uuidString.uppercased()
        if let named = characteristics[key] { return named }
        // Fast Pair short form FE2C12xx
        if key.count == 4, let named = characteristics[key] { return named }
        return ""
    }

    /// Maestro RFCOMM SDP endpoint, and the GFPS message stream endpoint. Both are
    /// Bluetooth Classic, so an iPhone never sees them in CoreBluetooth. Kept here
    /// because the log is also the evidence sheet for the write-up.
    static let maestroRFCOMM = "25e97ff7-24ce-4c4c-8951-f764a708f7b5"
    static let gfpsRFCOMM = "df21fe2c-2515-4fdb-8886-f12c4d67927c"
}

struct Peer: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var detail: String
}

struct CharacteristicRow: Identifiable {
    let id: String
    let uuid: CBUUID
    let name: String
    let properties: String
    let serviceUUID: CBUUID
    let characteristic: CBCharacteristic
}

// MARK: - probe

final class Probe: NSObject, ObservableObject {
    @Published var state = "init"
    @Published var scanning = false
    @Published var peers: [Peer] = []
    @Published var connectedName: String?
    @Published var rows: [CharacteristicRow] = []
    @Published private(set) var logLines: [String] = []
    private(set) var logStartID = 0
    @Published var relayStatus = ""

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var discovering = false
    private var discoveringServices = Set<ObjectIdentifier>()
    private var pendingSubscriptions = Set<ObjectIdentifier>()
    private var peerUpdates: [UUID: Date] = [:]
    private var pendingLogs: [String] = []
    private var logTimer: Timer?
    private static let logLimit = 2_000
    private let relay = LogRelay()

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.flushLogs()
        }
        timer.tolerance = 0.025
        logTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: log

    deinit {
        logTimer?.invalidate()
    }

    func log(_ message: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.log(message) }
            return
        }
        let stamp = Self.formatter.string(from: Date())
        let line = "\(stamp) \(message)"
        pendingLogs.append(line)
        // Bound even the unpublished buffer if the run loop misses timer ticks.
        if pendingLogs.count > Self.logLimit {
            pendingLogs.removeFirst(pendingLogs.count - Self.logLimit)
        }
        print(line)
    }

    private func flushLogs() {
        guard !pendingLogs.isEmpty else { return }
        var snapshot = logLines
        snapshot.append(contentsOf: pendingLogs)
        pendingLogs.removeAll(keepingCapacity: true)
        let excess = max(0, snapshot.count - Self.logLimit)
        if excess > 0 { snapshot.removeFirst(excess) }
        logStartID += excess
        logLines = snapshot
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var logText: String { (logLines + pendingLogs).suffix(Self.logLimit).joined(separator: "\n") }

    // MARK: scanning

    func startScan() {
        guard let manager, manager.state == .poweredOn else {
            log("scan blocked, bluetooth state \(state)")
            return
        }
        peers.removeAll()
        peerUpdates.removeAll()
        scanning = true
        log("scan started (all services, duplicates on)")
        manager.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        manager?.stopScan()
        scanning = false
        log("scan stopped, \(peers.count) device(s)")
    }

    func connect(_ peer: Peer) {
        guard peripheral == nil, let manager else { return }
        manager.stopScan()
        scanning = false
        resetSession()
        peripheral = peer.peripheral
        peer.peripheral.delegate = self
        connectedName = peer.name
        log("connecting to \(peer.name) \(peer.id.uuidString)")
        manager.connect(peer.peripheral, options: nil)
    }

    func disconnect() {
        if let p = peripheral {
            log("disconnect requested")
            manager?.cancelPeripheralConnection(p)
        }
    }

    var connectedAddress: String? { peripheral?.identifier.uuidString }

    // MARK: actions

    func rediscover() {
        guard let p = peripheral, p.state == .connected, !discovering else { return }
        // Rediscovery while notifications are streaming repeats reads/subscriptions
        // and can flood CoreBluetooth's operation queue. Keep the current dump.
        guard pendingSubscriptions.isEmpty,
              !rows.contains(where: { $0.characteristic.isNotifying }) else {
            log("discoverServices skipped: notifications active")
            return
        }
        rows.removeAll()
        discovering = true
        log("discoverServices(nil)")
        p.discoverServices(nil)
    }

    func readAll() {
        guard let p = peripheral, p.state == .connected, !discovering else { return }
        for row in rows where row.characteristic.properties.contains(.read) {
            log("read \(label(row.uuid))")
            p.readValue(for: row.characteristic)
        }
    }

    func subscribeAll() {
        guard let p = peripheral, p.state == .connected, !discovering else { return }
        for row in rows {
            let props = row.characteristic.properties
            if !row.characteristic.isNotifying, props.contains(.notify) || props.contains(.indicate),
               pendingSubscriptions.insert(ObjectIdentifier(row.characteristic)).inserted {
                log("subscribe \(label(row.uuid))")
                p.setNotifyValue(true, for: row.characteristic)
            }
        }
    }

    // Generic GATT operations for Explore. Pixel Buds controls use HTTP only.
    func read(_ row: CharacteristicRow) {
        guard let peripheral, peripheral.state == .connected else {
            log("ERROR: phone device is not connected"); return
        }
        peripheral.readValue(for: row.characteristic)
    }

    func notify(_ row: CharacteristicRow, enabled: Bool) {
        guard let peripheral, peripheral.state == .connected else {
            log("ERROR: phone device is not connected"); return
        }
        peripheral.setNotifyValue(enabled, for: row.characteristic)
    }

    @MainActor
    func prepareWrite(addr: String, characteristicID: String) async throws {
        if connectedAddress != addr {
            guard peripheral == nil else {
                throw NSError(domain: "PhoneBLE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnect the current phone device first"])
            }
            guard let peer = peers.first(where: { $0.id.uuidString == addr }) else {
                throw NSError(domain: "PhoneBLE", code: 2, userInfo: [NSLocalizedDescriptionKey: "Scan on the phone to find this saved device again"])
            }
            connect(peer)
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try Task.checkCancellation()
            guard connectedAddress == addr else {
                throw NSError(domain: "PhoneBLE", code: 3, userInfo: [NSLocalizedDescriptionKey: "Phone device disconnected"])
            }
            if peripheral?.state == .connected, !discovering {
                guard rows.contains(where: { $0.id == characteristicID || $0.uuid.uuidString == characteristicID }) else {
                    throw NSError(domain: "PhoneBLE", code: 4, userInfo: [NSLocalizedDescriptionKey: "Characteristic not found after discovery"])
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        disconnect()
        throw URLError(.timedOut)
    }

    func write(characteristicID: String, hex: String) throws {
        guard let peripheral, peripheral.state == .connected else {
            throw NSError(domain: "PhoneBLE", code: 5, userInfo: [NSLocalizedDescriptionKey: "Connect and discover the characteristic first"])
        }
        let candidates = rows.filter { $0.id == characteristicID || $0.uuid.uuidString == characteristicID }
        guard candidates.count == 1, let row = candidates.first else {
            throw NSError(domain: "PhoneBLE", code: 9, userInfo: [NSLocalizedDescriptionKey: "Characteristic missing or UUID is ambiguous; open the device and choose a specific characteristic"])
        }
        let bytes = Self.parseHex(hex)
        guard !bytes.isEmpty else { throw URLError(.cannotDecodeContentData) }
        let props = row.characteristic.properties
        guard props.contains(.write) || props.contains(.writeWithoutResponse) else {
            throw NSError(domain: "PhoneBLE", code: 6, userInfo: [NSLocalizedDescriptionKey: "Characteristic is not writable"])
        }
        let type: CBCharacteristicWriteType = props.contains(.write) ? .withResponse : .withoutResponse
        guard bytes.count <= peripheral.maximumWriteValueLength(for: type) else {
            throw NSError(domain: "PhoneBLE", code: 7, userInfo: [NSLocalizedDescriptionKey: "Payload exceeds peripheral maximum write length"])
        }
        if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            throw NSError(domain: "PhoneBLE", code: 8, userInfo: [NSLocalizedDescriptionKey: "Bluetooth write queue is full; try again"])
        }
        peripheral.writeValue(Data(bytes), for: row.characteristic, type: type)
        log("TX GATT \(row.uuid.uuidString): \(Data(bytes).hex)")
    }

    private func resetSession() {
        discovering = false
        discoveringServices.removeAll()
        pendingSubscriptions.removeAll()
        rows.removeAll()
    }

    static func parseHex(_ text: String) -> [UInt8] {
        guard text.utf8.count <= 196_608 else { return [] }
        let cleaned = text.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let tokens = cleaned.split(whereSeparator: { $0.isWhitespace })
        var out: [UInt8] = []
        for token in tokens {
            guard token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return [] }
            var index = token.startIndex
            while index < token.endIndex {
                let next = token.index(index, offsetBy: 2, limitedBy: token.endIndex) ?? token.endIndex
                guard let value = UInt8(token[index..<next], radix: 16) else { return [] }
                out.append(value)
                index = next
            }
        }
        return out
    }

    // MARK: relay

    func pushLogToServer() {
        guard LogRelay.endpoint != nil else {
            relayStatus = "disabled (configure logRelayURL)"
            return
        }
        let body = logText
        guard !body.isEmpty else { return }
        relayStatus = "sending"
        log("relay: sending \(body.count) chars")
        relay.post(body) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let code):
                    self.relayStatus = code == 0 ? "disabled" : "sent (\(code))"
                    self.log("relay: ok \(code)")
                case .failure(let error):
                    self.relayStatus = "failed: \(error.localizedDescription)"
                    self.log("relay: failed \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: formatting

    func label(_ uuid: CBUUID) -> String {
        let name = Known.characteristicName(uuid)
        return name.isEmpty ? uuid.uuidString : "\(uuid.uuidString) (\(name))"
    }

    func serviceLabel(_ uuid: CBUUID) -> String {
        let name = Known.serviceName(uuid)
        return name.isEmpty ? uuid.uuidString : "\(uuid.uuidString) (\(name))"
    }

    private func noteValue(_ data: Data?, characteristic: CBCharacteristic) {
        guard let data else {
            log("  value nil for \(label(characteristic.uuid))")
            return
        }
        log("  <- \(label(characteristic.uuid)) = \(data.hex)  |\(data.printable)|")
        if characteristic.uuid == CBUUID(string: "2A19"), let first = data.first {
            log("  battery level \(first)%")
        }
    }
}

// MARK: - central delegate

extension Probe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = "poweredOn"
        case .poweredOff: state = "poweredOff"
        case .unauthorized: state = "unauthorized"
        case .unsupported: state = "unsupported"
        case .resetting: state = "resetting"
        case .unknown: state = "unknown"
        @unknown default: state = "other"
        }
        if central.state != .poweredOn {
            scanning = false
            resetSession()
            peripheral?.delegate = nil
            peripheral = nil
            connectedName = nil
        }
        log("central state -> \(state)")
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard scanning else { return }
        let now = Date()
        if let last = peerUpdates[peripheral.identifier], now.timeIntervalSince(last) < 0.5 { return }
        if peerUpdates[peripheral.identifier] == nil, peers.count >= 256 { return }
        peerUpdates[peripheral.identifier] = now
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? "unnamed"
        var detail: [String] = []
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            detail.append("svc=" + services.map(\.uuidString).joined(separator: ","))
        }
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            detail.append("mfr=" + data.hex)
        }
        if let map = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (key, value) in map { detail.append("sd[\(key.uuidString)]=" + value.hex) }
        }
        if advertisementData[CBAdvertisementDataIsConnectable] != nil {
            detail.append("connectable")
        }
        let summary = detail.joined(separator: " ")

        if let index = peers.firstIndex(where: { $0.id == peripheral.identifier }) {
            peers[index].rssi = RSSI.intValue
            peers[index].name = name
            peers[index].detail = summary
        } else {
            peers.append(Peer(id: peripheral.identifier,
                              peripheral: peripheral,
                              name: name,
                              rssi: RSSI.intValue,
                              detail: summary))
            log("seen \(name) \(peripheral.identifier.uuidString) rssi \(RSSI.intValue) \(summary)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("connected \(peripheral.name ?? peripheral.identifier.uuidString)")
        connectedName = peripheral.name ?? peripheral.identifier.uuidString
        peripheral.delegate = self
        discovering = true
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral === self.peripheral else { return }
        log("connect failed: \(error?.localizedDescription ?? "unknown")")
        resetSession()
        peripheral.delegate = nil
        self.peripheral = nil
        connectedName = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral === self.peripheral else { return }
        log("disconnected: \(error?.localizedDescription ?? "clean")")
        resetSession()
        connectedName = nil
        peripheral.delegate = nil
        self.peripheral = nil
    }
}

// MARK: - peripheral delegate

extension Probe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral, peripheral.state == .connected, discovering else { return }
        if let error { log("discoverServices error: \(error.localizedDescription)") }
        let services = error == nil ? peripheral.services ?? [] : []
        discoveringServices = Set(services.map { ObjectIdentifier($0) })
        if services.isEmpty { discovering = false }
        log("discovered \(services.count) service(s)")
        for service in services {
            log("  service \(serviceLabel(service.uuid))")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard peripheral === self.peripheral, peripheral.state == .connected,
              discoveringServices.remove(ObjectIdentifier(service)) != nil else { return }
        defer { if discoveringServices.isEmpty { discovering = false } }
        if let error { log("discoverCharacteristics error: \(error.localizedDescription)") }
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            guard rows.count < 1024 else { break }
            var props: [String] = []
            let p = characteristic.properties
            if p.contains(.read) { props.append("read") }
            if p.contains(.write) { props.append("write") }
            if p.contains(.writeWithoutResponse) { props.append("writeNR") }
            if p.contains(.notify) { props.append("notify") }
            if p.contains(.indicate) { props.append("indicate") }
            if p.contains(.authenticatedSignedWrites) { props.append("signed") }
            if p.contains(.broadcast) { props.append("broadcast") }
            log("  char \(label(characteristic.uuid)) [\(props.joined(separator: ","))]")

            let row = CharacteristicRow(id: "\(ObjectIdentifier(characteristic))",
                                        uuid: characteristic.uuid,
                                        name: Known.characteristicName(characteristic.uuid),
                                        properties: props.joined(separator: ","),
                                        serviceUUID: service.uuid,
                                        characteristic: characteristic)
            guard !rows.contains(where: { $0.id == row.id }) else { continue }
            rows.append(row)
            if p.contains(.read) { peripheral.readValue(for: characteristic) }
            if !characteristic.isNotifying, p.contains(.notify) || p.contains(.indicate),
               pendingSubscriptions.insert(ObjectIdentifier(characteristic)).inserted {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, peripheral.state == .connected else { return }
        if let error {
            log("value error \(label(characteristic.uuid)): \(error.localizedDescription)")
            return
        }
        noteValue(characteristic.value, characteristic: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, peripheral.state == .connected else { return }
        if let error { log("write error \(label(characteristic.uuid)): \(error.localizedDescription)") }
        else { log("write ok \(label(characteristic.uuid))") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard peripheral === self.peripheral, peripheral.state == .connected else { return }
        pendingSubscriptions.remove(ObjectIdentifier(characteristic))
        if let error {
            log("notify state error \(label(characteristic.uuid)): \(error.localizedDescription)")
        } else {
            log("notify \(characteristic.isNotifying ? "on" : "off") \(label(characteristic.uuid))")
        }
    }

}
