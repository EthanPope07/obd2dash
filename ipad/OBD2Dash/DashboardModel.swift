import SwiftUI
import CoreBluetooth
import Combine

/// All CoreBluetooth callbacks and published state use the main queue.
final class DashboardModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "973a0001-6f8a-4db7-a735-79d348be7341")
    static let stream = CBUUID(string: "973a0002-6f8a-4db7-a735-79d348be7341")
    private let rememberedKey = "OBD2Dash.peripheral"
    @Published private(set) var connection = "Starting Bluetooth"
    @Published private(set) var streaming = false
    @Published private(set) var rows: [PIDRow] = []
    @Published private(set) var received = 0
    @Published private(set) var dropped = 0
    @Published private(set) var discovery = "Waiting for support maps"
    @Published private(set) var deviceName = "OBD2Dash"
    @Published var selectedECU: UInt16 = 0x7e8
    @Published var query = ""
    @Published var now = Date()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var assembler = PacketAssembler()
    private var store = PIDStore()
    private var deadline: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var clock: Timer?
    private var active = true
    private var demo = false

    var ecus: [UInt16] { Array(Set(rows.map { $0.key.ecu })).sorted() }
    var filteredRows: [PIDRow] {
        rows.filter { row in
            query.isEmpty || "\(row.key.code) \(row.key.ecuLabel) \(PIDCatalog.name(row.key.pid))"
                .localizedCaseInsensitiveContains(query)
        }
    }

    override init() {
        super.init()
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            demo = true
            loadDemo()
        } else {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()
            if self?.demo == true { self?.loadDemo() }
        }
    }
    deinit { clock?.invalidate(); deadline?.cancel(); retry?.cancel() }

    func setActive(_ value: Bool) {
        active = value
        guard !demo else { return }
        if value { scan() } else {
            retry?.cancel(); deadline?.cancel()
            central.stopScan()
            streaming = false
            connection = "Paused in background"
            assembler.reset()
            if let p = peripheral { peripheral = nil; central.cancelPeripheralConnection(p) }
        }
    }
    func reconnect() {
        guard !demo else { return }
        retry?.cancel(); deadline?.cancel(); central.stopScan()
        streaming = false; assembler.reset()
        if let p = peripheral { peripheral = nil; central.cancelPeripheralConnection(p) }
        scheduleScan()
    }
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: rememberedKey)
        reconnect()
    }

    private func scheduleScan() {
        guard active, central.state == .poweredOn else { return }
        retry?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.scan() }
        retry = job
        DispatchQueue.main.asyncAfter(deadline: .now()+2, execute: job)
    }
    private func scan() {
        guard active, central.state == .poweredOn, peripheral == nil, !central.isScanning else { return }
        connection = UserDefaults.standard.string(forKey: rememberedKey) == nil
            ? "Looking for OBD2Dash" : "Looking for your OBD2Dash"
        central.scanForPeripherals(withServices: [Self.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        deadline?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral == nil else { return }
            self.central.stopScan()
            self.connection = "Device not found · retrying"
            self.scheduleScan()
        }
        deadline = job
        DispatchQueue.main.asyncAfter(deadline: .now()+12, execute: job)
    }
    private func fail(_ message: String) {
        connection = message; streaming = false; assembler.reset()
        deadline?.cancel()
        if let p = peripheral { peripheral = nil; central.cancelPeripheralConnection(p) }
        scheduleScan()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !demo else { return }
        switch central.state {
        case .poweredOn: scan()
        case .poweredOff: fail("Turn on Bluetooth")
        case .unauthorized: fail("Allow Bluetooth in iPad Settings")
        case .unsupported: fail("Bluetooth LE is unavailable")
        case .resetting: fail("Bluetooth is restarting")
        default: connection = "Starting Bluetooth"
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover found: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard active, peripheral == nil else { return }
        if let remembered = UserDefaults.standard.string(forKey: rememberedKey),
           remembered != found.identifier.uuidString { return }
        central.stopScan(); deadline?.cancel()
        peripheral = found; found.delegate = self
        deviceName = found.name ?? "OBD2Dash"
        connection = "Connecting"
        central.connect(found, options: nil)
        let id = found.identifier
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral?.identifier == id, !self.streaming else { return }
            self.fail("Connection timed out · retrying")
        }
        deadline = job
        DispatchQueue.main.asyncAfter(deadline: .now()+15, execute: job)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard active, peripheral?.identifier == p.identifier else {
            central.cancelPeripheralConnection(p); return
        }
        store.clear(); rows = []; assembler.reset()
        discovery = "Waiting for support maps"; received = 0; dropped = 0
        connection = "Discovering telemetry service"
        p.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard peripheral?.identifier == p.identifier else { return }
        fail("Connection failed · retrying")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard peripheral?.identifier == p.identifier else { return }
        fail("Disconnected · reconnecting")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral?.identifier == p.identifier else { return }
        guard error == nil, let service = p.services?.first(where: { $0.uuid == Self.service }) else {
            fail("Telemetry service unavailable"); return
        }
        p.discoverCharacteristics([Self.stream], for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral?.identifier == p.identifier else { return }
        guard error == nil, let stream = service.characteristics?.first(where: { $0.uuid == Self.stream }),
              stream.properties.contains(.notify) else {
            fail("Telemetry stream unavailable"); return
        }
        connection = "Subscribing"
        p.setNotifyValue(true, for: stream)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral?.identifier == p.identifier, characteristic.uuid == Self.stream else { return }
        guard error == nil, characteristic.isNotifying else { fail("Subscription failed · retrying"); return }
        deadline?.cancel(); streaming = true; connection = "Connected"
        UserDefaults.standard.set(p.identifier.uuidString, forKey: rememberedKey)
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard streaming, peripheral?.identifier == p.identifier, characteristic.uuid == Self.stream else { return }
        guard error == nil, let data = characteristic.value else { dropped += 1; assembler.reset(); return }
        let before = assembler.rejected
        let record = assembler.accept(data, now: ProcessInfo.processInfo.systemUptime)
        dropped += assembler.rejected - before
        if let record {
            received += 1
            store.accept(record, at: Date())
            refreshRows()
        }
    }
    private func refreshRows() {
        rows = store.rows.values.sorted {
            $0.key.ecu == $1.key.ecu ? $0.key.pid < $1.key.pid : $0.key.ecu < $1.key.ecu
        }
        if !ecus.contains(selectedECU), let first = ecus.first { selectedECU = first }
        if !store.discovery.isEmpty {
            discovery = store.discovery.keys.sorted().map {
                String(format: "%03X", Int($0)) + ": " + (store.discovery[$0] ?? "")
            }.joined(separator: " · ")
        }
    }
    func gauge(_ pid: UInt8) -> Reading? {
        guard streaming, let row = store.rows[PIDKey(ecu: selectedECU, pid: pid)],
              row.isFresh(at: now) else { return nil }
        return row.reading
    }
    private func loadDemo() {
        connection = "Demo · simulated readings"; deviceName = "Demo dashboard"; streaming = true
        let examples: [(UInt8, [UInt8])] = [
            (0x0c,[0x1a,0xf8]), (0x0d,[64]), (0x05,[130]), (0x04,[94]),
            (0x11,[61]), (0x0f,[65]), (0x42,[0x36,0xb0]), (0x78,[1,2,3,4,5])
        ]
        for (pid, bytes) in examples {
            store.accept(TelemetryRecord(kind: 1, pid: pid, ecu: 0x7e8, sequence: 0,
                        status: 0, timestamp: 0, bytes: bytes), at: Date())
        }
        refreshRows()
        discovery = "Demo data only · no Bluetooth connection"
    }
}
