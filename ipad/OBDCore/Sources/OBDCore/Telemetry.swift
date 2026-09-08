import Foundation

public struct TelemetryRecord: Equatable {
    public let kind: UInt8
    public let pid: UInt8
    public let ecu: UInt16
    public let sequence: UInt16
    public let status: UInt8
    public let timestamp: UInt32
    public let bytes: [UInt8]
}

/// One sequential stream, matching the firmware's non-interleaved notifications.
public struct PacketAssembler {
    private struct Header: Equatable {
        let kind: UInt8, pid: UInt8, status: UInt8
        let ecu: UInt16, sequence: UInt16
        let total: Int
    }
    private var header: Header?
    private var payload: [UInt8] = []
    private var started: TimeInterval = 0
    public private(set) var rejected = 0
    public init() {}
    public mutating func reset() { header = nil; payload.removeAll(keepingCapacity: true) }
    private mutating func reject() { rejected += 1; reset() }

    public mutating func accept(_ data: Data, now: TimeInterval) -> TelemetryRecord? {
        if header != nil && now - started > 15 { reject() }
        let b = [UInt8](data)
        guard b.count == 20 else { reject(); return nil }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | (UInt16(b[i+1]) << 8) }
        let kind = b[0] & 15, offset = Int(u16(6)), total = Int(u16(8)), count = Int(b[11])
        guard b[0] >> 4 == 1, kind == 1 || kind == 2,
              (0x7e8...0x7ef).contains(u16(2)), b[10] <= 5,
              (4...4099).contains(total), (1...8).contains(count),
              offset + count <= total else { reject(); return nil }
        let next = Header(kind: kind, pid: b[1], status: b[10],
                          ecu: u16(2), sequence: u16(4), total: total)
        if offset == 0 {
            if header != nil { rejected += 1 }
            header = next; payload = []; started = now
        }
        guard header == next, payload.count == offset else { reject(); return nil }
        payload.append(contentsOf: b[12..<(12+count)])
        guard payload.count == total else { return nil }
        let timestamp = UInt32(payload[0]) | (UInt32(payload[1]) << 8)
            | (UInt32(payload[2]) << 16) | (UInt32(payload[3]) << 24)
        let record = TelemetryRecord(kind: kind, pid: next.pid, ecu: next.ecu,
            sequence: next.sequence, status: next.status, timestamp: timestamp,
            bytes: Array(payload.dropFirst(4)))
        reset()
        return record
    }
}

public struct PIDKey: Hashable, Identifiable {
    public let ecu: UInt16
    public let pid: UInt8
    public var id: Self { self }
    public init(ecu: UInt16, pid: UInt8) { self.ecu = ecu; self.pid = pid }
    public var code: String { String(format: "%02X", Int(pid)) }
    public var ecuLabel: String { String(format: "%03X", Int(ecu)) }
}

public struct Reading: Equatable {
    public let value: Double
    public let unit: String
    public let decimals: Int
    public var text: String { String(format: "%.*f", decimals, value) + " " + unit }
}

/// Only named scalar PIDs with known byte lengths are numerically decoded.
/// Everything else remains available as raw bytes, without guessed formulas.
public enum PIDCatalog {
    public static let names: [UInt8: String] = [
        0x01: "Monitor status", 0x02: "Freeze-frame DTC", 0x03: "Fuel system status",
        0x04: "Engine load", 0x05: "Coolant temperature",
        0x06: "Short fuel trim · bank 1", 0x07: "Long fuel trim · bank 1",
        0x08: "Short fuel trim · bank 2", 0x09: "Long fuel trim · bank 2",
        0x0A: "Fuel pressure", 0x0B: "Intake manifold pressure", 0x0C: "Engine speed",
        0x0D: "Vehicle speed", 0x0E: "Timing advance", 0x0F: "Intake temperature",
        0x10: "Mass air flow", 0x11: "Throttle position", 0x12: "Secondary air status",
        0x13: "Oxygen sensors present", 0x1C: "OBD standard", 0x1F: "Engine runtime",
        0x21: "Distance with MIL", 0x2F: "Fuel level", 0x33: "Barometric pressure",
        0x42: "Control module voltage", 0x46: "Ambient temperature", 0x5C: "Oil temperature"
    ]
    public static func name(_ pid: UInt8) -> String {
        names[pid] ?? String(format: "PID %02X", Int(pid))
    }
    public static func decode(_ pid: UInt8, bytes: [UInt8]) -> Reading? {
        guard let first = bytes.first else { return nil }
        let a = Double(first)
        func reading(_ value: Double, _ unit: String, _ decimals: Int = 1) -> Reading {
            Reading(value: value, unit: unit, decimals: decimals)
        }
        switch pid {
        case 0x04, 0x11, 0x2F:
            guard bytes.count == 1 else { return nil }; return reading(a * 100 / 255, "%")
        case 0x05, 0x0F, 0x46, 0x5C:
            guard bytes.count == 1 else { return nil }; return reading(a - 40, "°C", 0)
        case 0x06...0x09:
            guard bytes.count == 1 else { return nil }; return reading((a - 128) * 100 / 128, "%")
        case 0x0A:
            guard bytes.count == 1 else { return nil }; return reading(a * 3, "kPa", 0)
        case 0x0B, 0x33:
            guard bytes.count == 1 else { return nil }; return reading(a, "kPa", 0)
        case 0x0D:
            guard bytes.count == 1 else { return nil }; return reading(a, "km/h", 0)
        case 0x0E:
            guard bytes.count == 1 else { return nil }; return reading(a / 2 - 64, "°")
        case 0x0C, 0x10, 0x1F, 0x21, 0x42:
            guard bytes.count == 2 else { return nil }
            let word = a * 256 + Double(bytes[1])
            switch pid {
            case 0x0C: return reading(word / 4, "rpm", 0)
            case 0x10: return reading(word / 100, "g/s", 2)
            case 0x1F: return reading(word, "s", 0)
            case 0x21: return reading(word, "km", 0)
            default: return reading(word / 1000, "V", 2)
            }
        default: return nil
        }
    }
    public static func status(_ status: UInt8, bytes: [UInt8]) -> String {
        switch status {
        case 0: return "Received"
        case 1: return "Timed out"
        case 2: return bytes.first.map { String(format: "ECU rejected · NRC %02X", Int($0)) } ?? "ECU rejected"
        case 3: return "Malformed response"
        case 4: return "Transport error"
        default: return "CAN unavailable"
        }
    }
}

public struct PIDRow: Identifiable {
    public let key: PIDKey
    public var id: PIDKey { key }
    public var bytes: [UInt8] = []
    public var status: UInt8?
    public var receivedAt: Date?
    public var deviceTimestamp: UInt32?
    public var reading: Reading? {
        status == 0 ? PIDCatalog.decode(key.pid, bytes: bytes) : nil
    }
    public var raw: String { bytes.map { String(format: "%02X", Int($0)) }.joined(separator: " ") }
    public init(key: PIDKey) { self.key = key }
    public func isFresh(at date: Date, threshold: TimeInterval = 15) -> Bool {
        guard status == 0, let receivedAt else { return false }
        return date.timeIntervalSince(receivedAt) <= threshold
    }
}

public struct PIDStore {
    public private(set) var rows: [PIDKey: PIDRow] = [:]
    public private(set) var discovery: [UInt16: String] = [:]
    public init() {}
    public mutating func clear() { rows.removeAll(); discovery.removeAll() }
    public mutating func accept(_ record: TelemetryRecord, at date: Date) {
        if record.kind == 2 {
            guard record.status == 0 else {
                discovery[record.ecu] = "Discovery incomplete"; return
            }
            guard record.pid % 32 == 0, record.bytes.count == 4 else {
                discovery[record.ecu] = "Invalid support map"; return
            }
            discovery[record.ecu] = "Support map received"
            for bit in 0..<32 {
                let pid = Int(record.pid) + bit + 1
                guard pid < 256, pid % 32 != 0,
                      record.bytes[bit / 8] & UInt8(0x80 >> (bit % 8)) != 0 else { continue }
                let key = PIDKey(ecu: record.ecu, pid: UInt8(pid))
                if rows[key] == nil { rows[key] = PIDRow(key: key) }
            }
        } else {
            let key = PIDKey(ecu: record.ecu, pid: record.pid)
            var row = rows[key] ?? PIDRow(key: key)
            row.bytes = record.bytes; row.status = record.status
            row.receivedAt = date; row.deviceTimestamp = record.timestamp
            rows[key] = row
        }
    }
}
