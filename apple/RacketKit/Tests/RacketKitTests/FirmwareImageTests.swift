import XCTest
@testable import RacketKit

/// The racket checks the same CRC-32 (firmware/src/ota.cpp), and the app only offers newer firmware.
final class FirmwareImageTests: XCTestCase {
    func testCRC32MatchesStandardCheckValue() {
        XCTAssertEqual(FirmwareImage(data: Data("123456789".utf8), version: nil).crc32, 0xCBF4_3926)
    }

    func testVersionComparison() {
        let image = FirmwareImage(data: Data(), version: "1.10")
        XCTAssertTrue(image.isNewer(than: "1.9"))
        XCTAssertTrue(image.isNewer(than: "1.2"))
        XCTAssertFalse(image.isNewer(than: "1.10"))
        XCTAssertFalse(image.isNewer(than: "2.0"))
        XCTAssertFalse(FirmwareImage(data: Data(), version: nil).isNewer(than: "1.0"))
    }
}
