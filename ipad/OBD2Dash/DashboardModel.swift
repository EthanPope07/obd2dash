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
    @Published private(set) var demo = false
    private var demoElapsed: Double = 0

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
            if let self, self.demo, self.active {
                self.demoElapsed += 1
                self.loadDemo()
            }
        }
    }
    deinit { clock?.invalidate(); deadline?.cancel(); retry?.cancel() }

    func setActive(_ value: Bool) {
        active = value
        guard !demo else {
            if value { loadDemo() }
            return
        }
        if value { scan() } else {
            retry?.cancel(); deadline?.cancel()
            central.stopScan()
            streaming = false
            connection = "Paused in background"
            assembler.reset()
            if let p = peripheral { peripheral = nil; central.cancelPeripheralConnection(p) }
        }
    }
    // Simulation owns the data store while enabled. Late BLE callbacks cannot mix
    // vehicle data into the demo, and leaving demo starts with an empty store.
    func setDemo(_ enabled: Bool) {
        guard enabled != demo else { return }
        demo = enabled
        retry?.cancel(); deadline?.cancel()
        central?.stopScan()
        if let p = peripheral {
            peripheral = nil
            central?.cancelPeripheralConnection(p)
        }
        assembler.reset(); store.clear(); rows = []
        received = 0; dropped = 0; streaming = false
        query = ""; selectedECU = 0x7e8; now = Date()
        if enabled {
            demoElapsed = 0
            loadDemo()
        } else {
            deviceName = "OBD2Dash"
            discovery = "Waiting for support maps"
            connection = "Starting Bluetooth"
            if let central { centralManagerDidUpdateState(central) }
            else { central = CBCentralManager(delegate: self, queue: .main) }
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
        guard !demo, active, central.state == .poweredOn else { return }
        retry?.cancel()
        let job = DispatchWorkItem { [weak self] in self?.scan() }
        retry = job
        DispatchQueue.main.asyncAfter(deadline: .now()+2, execute: job)
    }
    private func scan() {
        guard !demo, active, central.state == .poweredOn, peripheral == nil, !central.isScanning else { return }
        connection = UserDefaults.standard.string(forKey: rememberedKey) == nil
            ? "Looking for OBD2Dash" : "Looking for your OBD2Dash"
        central.scanForPeripherals(withServices: [Self.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        deadline?.cancel()
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.demo, self.active, self.peripheral == nil else { return }
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
        guard !demo, active, peripheral == nil else { return }
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
        guard !demo, active, peripheral?.identifier == p.identifier else {
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
        connection = "Demo · simulated readings"
        deviceName = "2017 Infiniti QX70"
        streaming = true
        // Illustrative stop-and-go drive, not a captured QX70 trace or verified
        // PID support inventory. All samples use the normal production decoder.
        let phase = demoElapsed.truncatingRemainder(dividingBy: 100)
        let speed: Double
        switch phase {
        case 0..<10: speed = 0
        case 10..<35: speed = (phase - 10) * 3.2
        case 35..<65: speed = 80 + 4 * sin((phase - 35) / 5)
        case 65..<90: speed = max(0, 80 - (phase - 65) * 3.2)
        default: speed = 0
        }
        let accelerating = phase >= 10 && phase < 35
        let rpm = speed < 1 ? 720 + 25 * sin(demoElapsed / 3)
            : (accelerating ? 1500 + (speed.truncatingRemainder(dividingBy: 24)) * 80 : 1200 + speed * 14)
        let throttle = speed < 1 ? 4.0 : accelerating ? 38.0 : phase >= 65 ? 6.0 : 18.0
        let coolant = min(92.0, 72 + demoElapsed / 4)
        func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
        func word(_ value: Double) -> [UInt8] {
            let n = UInt16(max(0, min(65535, value.rounded())))
            return [UInt8(n >> 8), UInt8(n & 255)]
        }
        let examples: [(UInt8, [UInt8])] = [
            (0x0c, word(rpm * 4)), (0x0d, [byte(speed)]), (0x05, [byte(coolant + 40)]),
            (0x04, [byte((accelerating ? 65 : speed < 1 ? 18 : 32) * 2.55)]),
            (0x11, [byte(throttle * 2.55)]), (0x0f, [byte(68 + 2 * sin(demoElapsed / 15))]),
            (0x42, word(13900 + 120 * sin(demoElapsed / 8))),
            (0x06, [byte(128 + 4 * sin(demoElapsed / 4))]),
            (0x07, [130]), (0x08, [byte(128 + 3 * sin(demoElapsed / 5))]), (0x09, [129]),
            (0x0b, [byte(speed < 1 ? 32 : accelerating ? 78 : 42)]),
            (0x0e, [byte((speed < 1 ? 10 : 28) * 2 + 128)]),
            (0x10, word((speed < 1 ? 4.5 : 12 + speed * 0.35) * 100)),
            (0x1f, word(demoElapsed)), (0x2f, [byte(68 * 2.55)]),
            (0x33, [101]), (0x46, [64]), (0x5c, [byte(min(98, 65 + demoElapsed / 3) + 40)])
        ]
        for (pid, bytes) in examples {
            store.accept(TelemetryRecord(kind: 1, pid: pid, ecu: 0x7e8, sequence: 0,
                        status: 0, timestamp: UInt32(min(demoElapsed * 1000, Double(UInt32.max))),
                        bytes: bytes), at: now)
        }
        received += examples.count
        refreshRows()
        discovery = "SIMULATED · Illustrative QX70 drive · PID support is not verified for your vehicle · Bluetooth paused"
    }
}
