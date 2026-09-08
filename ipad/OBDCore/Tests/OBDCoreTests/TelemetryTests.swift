import XCTest
@testable import OBDCore

final class TelemetryTests: XCTestCase {
    func packet(offset: Int = 0, total: Int = 6, payload: [UInt8] = [0,0,0,0,0x1a,0xf8],
                kind: UInt8 = 1, pid: UInt8 = 0x0c) -> Data {
        var p: [UInt8] = [0x10 | kind,pid,0xe8,7,0,0,UInt8(offset & 255),UInt8(offset >> 8),
                           UInt8(total & 255),UInt8(total >> 8),0,UInt8(payload.count)]
        p += payload; p += Array(repeating: 0, count: 20-p.count)
        return Data(p)
    }
    func testFirmwareRPMVector() throws {
        var decoder = PacketAssembler()
        let record = try XCTUnwrap(decoder.accept(packet(), now: 0))
        XCTAssertEqual(record.ecu, 0x7e8)
        XCTAssertEqual(PIDCatalog.decode(record.pid, bytes: record.bytes)?.value, 1726)
    }
    func testGapAndMalformedAreRejected() {
        var d = PacketAssembler()
        XCTAssertNil(d.accept(packet(offset: 8, total: 12, payload: [1,2,3,4]), now: 0))
        XCTAssertNil(d.accept(Data([0]), now: 0))
        XCTAssertEqual(d.rejected, 2)
    }
    func testFragmentationAndTimeout() {
        var d = PacketAssembler()
        let first = packet(total: 12, payload: [1,0,0,0,1,2,3,4])
        XCTAssertNil(d.accept(first, now: 0))
        XCTAssertNil(d.accept(packet(offset: 8, total: 12, payload: [5,6,7,8]), now: 16))
        XCTAssertNil(d.accept(first, now: 17))
        let r = d.accept(packet(offset: 8, total: 12, payload: [5,6,7,8]), now: 18)
        XCTAssertEqual(r?.bytes, [1,2,3,4,5,6,7,8])
    }
    func testScalarLengthsAndUnknownPID() {
        XCTAssertNil(PIDCatalog.decode(0x0c, bytes: [1]))
        XCTAssertNil(PIDCatalog.decode(0x78, bytes: [1,2,3]))
        XCTAssertEqual(PIDCatalog.decode(0x05, bytes: [130])?.value, 90)
        XCTAssertEqual(PIDCatalog.decode(0x06, bytes: [128])?.value, 0)
    }
    func testSupportMapsAndErrorsDoNotInventValues() throws {
        var d = PacketAssembler(), store = PIDStore()
        let record = try XCTUnwrap(d.accept(packet(total: 8, payload: [0,0,0,0,0x80,0,0,1],
                                                   kind: 2, pid: 0), now: 0))
        store.accept(record, at: Date())
        XCTAssertNotNil(store.rows[PIDKey(ecu: 0x7e8, pid: 1)])
        XCTAssertNil(store.rows[PIDKey(ecu: 0x7e8, pid: 32)])
        XCTAssertNil(store.rows[PIDKey(ecu: 0x7e9, pid: 1)])
        XCTAssertNil(store.rows[PIDKey(ecu: 0x7e8, pid: 1)]?.reading)
    }
    func testFailureReplacesSuccess() throws {
        var d = PacketAssembler(), store = PIDStore()
        let success = try XCTUnwrap(d.accept(packet(), now: 0))
        store.accept(success, at: Date(timeIntervalSince1970: 0))
        var fail = [UInt8](packet(total: 4, payload: [0,0,0,0]))
        fail[10] = 1
        let failure = try XCTUnwrap(d.accept(Data(fail), now: 1))
        store.accept(failure, at: Date(timeIntervalSince1970: 1))
        XCTAssertNil(store.rows[PIDKey(ecu: 0x7e8, pid: 0x0c)]?.reading)
    }
}
