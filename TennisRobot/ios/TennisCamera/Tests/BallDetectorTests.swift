import XCTest
@testable import TennisCamera

/// Full-range 4:2:0 frame built from RGB rectangles and discs.
///
/// The chroma plane is averaged over each 2x2 block exactly as the camera ISP
/// does, so these tests also exercise the edge behaviour the real pipeline sees
/// rather than handing the detector a chroma plane that is too clean.
struct SyntheticFrame {
    struct Patch {
        var cx: Double
        var cy: Double
        var radius: Double
        var r: Double
        var g: Double
        var b: Double
    }

    let width: Int
    let height: Int
    var luma: [UInt8]
    var chroma: [UInt8]

    init(
        width: Int,
        height: Int,
        background: (Double, Double, Double),
        patches: [Patch] = [],
        stripe: (x: Int, y: Int, w: Int, h: Int, r: Double, g: Double, b: Double)? = nil
    ) {
        self.width = width
        self.height = height
        luma = [UInt8](repeating: 0, count: width * height)
        chroma = [UInt8](repeating: 0, count: (width / 2) * (height / 2) * 2)

        var rgb = [(Double, Double, Double)](repeating: background, count: width * height)

        if let s = stripe {
            for y in max(0, s.y)..<min(height, s.y + s.h) {
                for x in max(0, s.x)..<min(width, s.x + s.w) {
                    rgb[y * width + x] = (s.r, s.g, s.b)
                }
            }
        }

        for patch in patches {
            let x0 = max(0, Int(patch.cx - patch.radius) - 1)
            let x1 = min(width, Int(patch.cx + patch.radius) + 2)
            let y0 = max(0, Int(patch.cy - patch.radius) - 1)
            let y1 = min(height, Int(patch.cy + patch.radius) + 2)
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let dx = Double(x) - patch.cx
                    let dy = Double(y) - patch.cy
                    if dx * dx + dy * dy <= patch.radius * patch.radius {
                        rgb[y * width + x] = (patch.r, patch.g, patch.b)
                    }
                }
            }
        }

        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = rgb[y * width + x]
                let yValue = 0.299 * r + 0.587 * g + 0.114 * b
                luma[y * width + x] = UInt8(clamping: Int(yValue.rounded()))
            }
        }

        let chromaWidth = width / 2
        for cy in 0..<(height / 2) {
            for cx in 0..<chromaWidth {
                var r = 0.0, g = 0.0, b = 0.0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let (pr, pg, pb) = rgb[(cy * 2 + dy) * width + cx * 2 + dx]
                        r += pr; g += pg; b += pb
                    }
                }
                r /= 4; g /= 4; b /= 4
                let cb = -0.168_736 * r - 0.331_264 * g + 0.5 * b + 128
                let cr = 0.5 * r - 0.418_688 * g - 0.081_312 * b + 128
                let offset = (cy * chromaWidth + cx) * 2
                chroma[offset] = UInt8(clamping: Int(cb.rounded()))
                chroma[offset + 1] = UInt8(clamping: Int(cr.rounded()))
            }
        }
    }

    func detect(_ detector: BallDetector, roi: CGRect? = nil) -> [BallDetection] {
        luma.withUnsafeBufferPointer { lumaBuffer in
            chroma.withUnsafeBufferPointer { chromaBuffer in
                detector.detect(
                    luma: lumaBuffer.baseAddress!,
                    lumaStride: width,
                    chroma: chromaBuffer.baseAddress!,
                    chromaStride: width,
                    width: width,
                    height: height,
                    roi: roi
                )
            }
        }
    }
}

final class BallDetectorTests: XCTestCase {
    private let tennisBall = (r: 220.0, g: 235.0, b: 40.0)
    private let frameWidth = 1920
    private let frameHeight = 1080

    func testSyntheticYellowBallCentroidAndRadius() {
        let detector = BallDetector()
        let frame = SyntheticFrame(
            width: frameWidth,
            height: frameHeight,
            background: (40, 60, 90),
            patches: [.init(cx: 900, cy: 520, radius: 40, r: tennisBall.r, g: tennisBall.g, b: tennisBall.b)]
        )

        let detections = frame.detect(detector)
        XCTAssertEqual(detections.count, 1, "one synthetic ball in an empty scene")
        guard let detection = detections.first else { return }

        XCTAssertEqual(Double(detection.u), 900, accuracy: 1.0, "centroid u")
        XCTAssertEqual(Double(detection.v), 520, accuracy: 1.0, "centroid v")
        XCTAssertEqual(Double(detection.radius), 40, accuracy: 1.0, "radius sqrt(area/pi)")
        XCTAssertGreaterThan(detection.confidence, 0.9, "a disc should score as a disc")
    }

    func testGrayAndBlueFramesProduceNoDetection() {
        let detector = BallDetector()

        let gray = SyntheticFrame(width: frameWidth, height: frameHeight, background: (128, 128, 128))
        XCTAssertTrue(gray.detect(detector).isEmpty, "neutral gray is not a tennis ball")

        let blue = SyntheticFrame(width: frameWidth, height: frameHeight, background: (30, 70, 200))
        XCTAssertTrue(blue.detect(detector).isEmpty, "blue is not a tennis ball")

        // A bright, unsaturated warm wall must not pass either.
        let beige = SyntheticFrame(width: frameWidth, height: frameHeight, background: (200, 195, 170))
        XCTAssertTrue(beige.detect(detector).isEmpty, "unsaturated beige is not a tennis ball")
    }

    func testROIReportsFullFrameCoordinates() {
        let detector = BallDetector()
        let frame = SyntheticFrame(
            width: frameWidth,
            height: frameHeight,
            background: (40, 60, 90),
            patches: [.init(cx: 600, cy: 400, radius: 25, r: tennisBall.r, g: tennisBall.g, b: tennisBall.b)]
        )

        // ROI covers x 480...960, y 270...540: the ball is inside it.
        let roi = CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)
        let inside = frame.detect(detector, roi: roi)
        XCTAssertEqual(inside.count, 1)
        XCTAssertEqual(Double(inside.first?.u ?? 0), 600, accuracy: 1.0, "ROI offset must be added back")
        XCTAssertEqual(Double(inside.first?.v ?? 0), 400, accuracy: 1.0)

        // ROI that excludes the ball must find nothing.
        let elsewhere = CGRect(x: 0.6, y: 0.6, width: 0.35, height: 0.35)
        XCTAssertTrue(frame.detect(detector, roi: elsewhere).isEmpty)
    }

    func testYellowStripeIsRejectedByShape() {
        let detector = BallDetector()
        let stripe = SyntheticFrame(
            width: frameWidth,
            height: frameHeight,
            background: (40, 60, 90),
            stripe: (x: 700, y: 500, w: 520, h: 26, r: tennisBall.r, g: tennisBall.g, b: tennisBall.b)
        )
        XCTAssertTrue(stripe.detect(detector).isEmpty, "a long yellow stripe is not a ball")
    }

    func testTwoBallsAreBothReported() {
        let detector = BallDetector()
        let frame = SyntheticFrame(
            width: frameWidth,
            height: frameHeight,
            background: (40, 60, 90),
            patches: [
                .init(cx: 500, cy: 400, radius: 18, r: tennisBall.r, g: tennisBall.g, b: tennisBall.b),
                .init(cx: 1400, cy: 700, radius: 30, r: tennisBall.r, g: tennisBall.g, b: tennisBall.b),
            ]
        )

        let detections = frame.detect(detector)
        XCTAssertEqual(detections.count, 2)
        let us = Set(detections.map { Int(($0.u / 100).rounded()) })
        XCTAssertEqual(us, [5, 14], "both centroids present")
    }

    /// Not a performance gate (the simulator is not the phone), but a regression
    /// guard: this detector is supposed to be a couple of milliseconds, not tens.
    func testFullFrameDetectorTiming() {
        let detector = BallDetector()
        let frame = SyntheticFrame(
            width: frameWidth,
            height: frameHeight,
            background: (150, 160, 120),
            patches: [.init(cx: 900, cy: 520, radius: 40, r: tennisBall.r, g: tennisBall.g, b: tennisBall.b)]
        )

        var samples: [Double] = []
        for _ in 0..<30 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = frame.detect(detector)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "detector 1920x1080 full frame: median %.2f ms, p95 %.2f ms (simulator)",
                     median, sorted[Int(Double(sorted.count) * 0.95)]))
        XCTAssertLessThan(median, 40, "detector should stay in single-digit ms")
    }
}
