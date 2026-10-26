import XCTest
@testable import TennisCamera

/// The byte layout is a contract with the Python receiver and, later, the
/// Windows PC. These expectations were produced by
///
///     struct.Struct("<I B B H I Q f f f f H H").pack(...)
///
/// so a drifting field order or a stray Swift padding byte fails here rather
/// than on the robot.
final class ObservationPacketTests: XCTestCase {
    func testObservationPacketMatchesPythonStruct() {
        let packet = ObservationPacket(
            kind: .observation,
            sequence: 1234,
            tCaptureNs: 1_600_000_000_123_456_789,
            u: 640.5,
            v: 360.25,
            radius: 12.5,
            confidence: 0.875,
            width: 1920,
            height: 1080
        )

        let data = packet.encode()
        XCTAssertEqual(data.count, 40)
        XCTAssertEqual(
            data.hexString,
            "54524f4201002800d204000015cdfbdf85573416002020440020b443000048410000603f80073804"
        )
        XCTAssertEqual(String(data: data.prefix(4), encoding: .utf8), "TROB", "magic on the wire")
    }

    func testStatusPacketMatchesPythonStruct() {
        let packet = ObservationPacket(
            kind: .status,
            sequence: 99,
            tCaptureNs: 1_600_000_000_999_000_000,
            u: 238.5,
            v: 2.75,
            radius: 3,
            confidence: 1,
            width: 1920,
            height: 1080
        )
        XCTAssertEqual(
            packet.encode().hexString,
            "54524f420101280063000000c0872b148657341600806e4300003040000040400000803f80073804"
        )
    }

    func testRoundTrip() {
        let original = ObservationPacket(
            kind: .observation,
            sequence: 4_000_000_000,
            tCaptureNs: 42,
            u: 1.25,
            v: 1079.5,
            radius: 0.5,
            confidence: 0.125,
            width: 1920,
            height: 1080
        )
        guard let decoded = ObservationPacket(decoding: original.encode()) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.sequence, original.sequence)
        XCTAssertEqual(decoded.tCaptureNs, original.tCaptureNs)
        XCTAssertEqual(decoded.u, original.u)
        XCTAssertEqual(decoded.v, original.v)
        XCTAssertEqual(decoded.radius, original.radius)
        XCTAssertEqual(decoded.confidence, original.confidence)
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
        XCTAssertEqual(decoded.kind, original.kind)
    }

    func testRejectsShortOrCorruptPackets() {
        XCTAssertNil(ObservationPacket(decoding: Data(repeating: 0, count: 39)))

        var corrupt = [UInt8](Data(repeating: 0, count: 40))
        corrupt[0] = 0x00
        XCTAssertNil(ObservationPacket(decoding: Data(corrupt)), "bad magic")
    }

    func testStatusPacketCarriesThermalAndCounters() {
        let packet = ObservationPacket.status(
            sequence: 7,
            tCaptureNs: 0,
            measuredFPS: 239.5,
            detectorMedianMs: 3.25,
            droppedFrames: 11,
            thermalState: 2,
            width: 1920,
            height: 1080
        )
        XCTAssertEqual(packet.kind, .status)
        XCTAssertEqual(packet.u, 239.5)
        XCTAssertEqual(packet.v, 3.25)
        XCTAssertEqual(packet.radius, 11)
        XCTAssertEqual(packet.confidence, 2)
        XCTAssertEqual(packet.width, 1920)
        XCTAssertEqual(packet.height, 1080)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
