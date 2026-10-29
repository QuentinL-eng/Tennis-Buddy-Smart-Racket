import XCTest
import simd
@testable import RacketKit

final class ShotTypeTests: XCTestCase {
    /// A flat window with constant racket-frame rotation, so only the gyro sign can decide the type.
    private func shotType(wy: Float, sign: Float) -> ShotType {
        let window = (0..<1000).map { k in
            IMUSample(time: Double(k) * 0.001, accel: SIMD3(0, 0, 1), gyro: SIMD3(0, wy, 0), highG: .zero)
        }
        var profile = RacketProfile()
        profile.forehandBodySign = sign
        return ShotAnalyzer(profile: profile, model: ImpactModel())
            .analyze(window: window, impact: 700, orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                     date: Date(), calibrationMode: false).type
    }

    func testBodySignDecidesForehandVersusBackhand() {
        XCTAssertEqual(shotType(wy: 28, sign: 1), .forehand)
        XCTAssertEqual(shotType(wy: -28, sign: 1), .backhand)
        XCTAssertEqual(shotType(wy: 28, sign: -1), .backhand)
        XCTAssertEqual(shotType(wy: -28, sign: -1), .forehand)
    }

    func testBodySignIsOffByDefault() {
        XCTAssertEqual(RacketProfile().forehandBodySign, 0)
    }

    /// Saves made before the forehand sign existed must still load, or the app silently resets to defaults.
    func testOldSavesStillDecode() throws {
        let oldProfile = Data(#"{"name":"Yonex","massKg":0.3,"lengthM":0.68,"balancePointM":0.3,"stringCenterM":0.5,"imuFromButtM":0.04,"effectiveRadiusM":1.1,"rightHanded":false}"#.utf8)
        let profile = try JSONDecoder().decode(RacketProfile.self, from: oldProfile)
        XCTAssertEqual(profile.name, "Yonex")
        XCTAssertFalse(profile.rightHanded)
        XCTAssertEqual(profile.forehandBodySign, 0)
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("forehandBodySign"))

        let oldPlayer = Data(#"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"Quentin","rightHanded":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(PlayerProfile.self, from: oldPlayer).forehandBodySign)

        let oldFeatures = Data(#"{"rollRatio":0.1,"ringNorm":0.2,"jolt":0.3,"impulse":4}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ImpactFeatures.self, from: oldFeatures).spinAxisY)
    }
}
