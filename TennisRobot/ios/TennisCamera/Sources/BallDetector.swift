import CoreGraphics
import Foundation

/// One ball candidate in full-frame pixel coordinates.
///
/// `u`/`v` are pixel indices in the **full frame** (the ROI offset is already
/// added back), using the same convention as OpenCV and the Python pipeline's
/// `PinholeCamera`: pixel (0, 0) is the top-left sample. `radius` is
/// `sqrt(area / pi)` in full-frame pixels, matching
/// `src/tennisrobot/vision.py`.
struct BallDetection: Equatable {
    var u: Float
    var v: Float
    var radius: Float
    var confidence: Float
    /// Number of thresholded pixels in the blob. Diagnostics only.
    var area: Int
}

/// Threshold-and-centroid tennis-ball detector for 4:2:0 YCbCr frames.
///
/// This is a re-expression of `src/tennisrobot/vision.py::ColorBlobDetector`
/// that has to fit in 4.17 ms (one frame at 240 fps). It is not a port: OpenCV
/// is not available on the phone, and per-pixel HSV conversion of 2 megapixels
/// is far too slow.
///
/// The work is cut down in three ways:
///
/// 1. **Hue and saturation depend only on the chroma sample, never on luma.**
///    `Cb`/`Cr` differences fix `max(R,G,B) - min(R,G,B)` and the hue angle
///    exactly, so both are precomputed into a 64x64 lookup table and the
///    per-pixel test becomes one table read plus integer comparisons.
/// 2. **Pixels are visited in 2x2 groups** that share one chroma sample, so the
///    chroma decode and table read happen once per four pixels.
/// 3. **Connectivity is found on a 16x16 cell grid**, but area, centroid and
///    bounding box are accumulated at pixel resolution during the same pass, so
///    there is no contour pass, no morphology and no second sweep.
///
/// The one place this differs from the Python reference is the shape test. A
/// real perimeter needs contour tracing, which is the expensive part of the
/// OpenCV version; instead `confidence` is the smaller of the bounding-box fill
/// ratio and the bounding-box aspect ratio. A disc scores ~1.0, a long yellow
/// stripe scores near zero. See `README.md` for the trade-off.
final class BallDetector {
    struct HSVColor: Equatable {
        /// OpenCV hue scale, 0...179 (degrees / 2).
        var h: Int
        /// 0...255.
        var s: Int
        /// 0...255.
        var v: Int
    }

    struct Config {
        var hsvLower = HSVColor(h: 25, s: 70, v: 70)
        var hsvUpper = HSVColor(h: 50, s: 255, v: 255)
        var minAreaPx: Double = 40
        var minRadiusPx: Double = 3
        var maxRadiusPx: Double = 80
        /// Applied to the bounding-box fill/aspect proxy, not to a traced
        /// contour perimeter.
        var minCircularity: Double = 0.55
        var maxCandidates: Int = 3
        var minConfidence: Double = 0.25
        /// Cell-grid size for connectivity. Must be a power of two.
        var cellSizePx: Int = 16
        /// Normalised ROI in full-frame coordinates. Default: whole frame.
        var roi = CGRect(x: 0, y: 0, width: 1, height: 1)

        /// Whole frame. The default.
        static let fullFrameROI = CGRect(x: 0, y: 0, width: 1, height: 1)
        /// A generous band around the expected strike zone: 70% x 60% centred.
        static let strikeZoneROI = CGRect(x: 0.15, y: 0.2, width: 0.7, height: 0.6)
    }

    /// 6 bits per chroma axis: 4096 entries, 4 luma levels per bin.
    private static let lutSide = 64
    private static let lutShift = 6
    private static let lutSize = lutSide * lutSide

    private var config: Config

    private let hueMask: UnsafeMutablePointer<UInt8>
    private let deltaLUT: UnsafeMutablePointer<Int16>
    private let maxOffLUT: UnsafeMutablePointer<Int16>
    private let scratch = DetectorScratch()

    init(config: Config = Config()) {
        hueMask = .allocate(capacity: Self.lutSize)
        deltaLUT = .allocate(capacity: Self.lutSize)
        maxOffLUT = .allocate(capacity: Self.lutSize)
        hueMask.initialize(repeating: 0, count: Self.lutSize)
        deltaLUT.initialize(repeating: 0, count: Self.lutSize)
        maxOffLUT.initialize(repeating: 0, count: Self.lutSize)
        self.config = config
        rebuildLUT()
    }

    deinit {
        hueMask.deallocate()
        deltaLUT.deallocate()
        maxOffLUT.deallocate()
    }

    var currentConfig: Config {
        get { config }
        set {
            config = newValue
            rebuildLUT()
        }
    }

    // MARK: - Classification table

    /// Build the (Cb, Cr) -> hue/saturation table.
    ///
    /// Working in channel *differences* keeps this exact: adding the same luma
    /// to R, G and B does not change `max - min` or the hue, so the table does
    /// not have to be rebuilt per luminance level. Full-range BT.601:
    ///
    ///     R = Y + 1.402   Cr'          Cb' = Cb - 128
    ///     G = Y - 0.344136 Cb' - 0.714136 Cr'   Cr' = Cr - 128
    ///     B = Y + 1.772   Cb'
    private func rebuildLUT() {
        let lowerHue = Double(max(0, min(179, config.hsvLower.h))) * 2.0
        let upperHue = Double(max(0, min(179, config.hsvUpper.h))) * 2.0
        let lowerHueWraps = lowerHue > upperHue

        for bi in 0..<Self.lutSide {
            // Bin centre, so quantisation is symmetric.
            let cb = Double(bi * 4 + 2) - 128.0
            for bj in 0..<Self.lutSide {
                let cr = Double(bj * 4 + 2) - 128.0
                let k = (bi << Self.lutShift) | bj

                let dr = 1.402 * cr
                let dg = -0.344_136 * cb - 0.714_136 * cr
                let db = 1.772 * cb

                let mx = max(dr, max(dg, db))
                let mn = min(dr, min(dg, db))
                let delta = mx - mn

                deltaLUT[k] = Int16(delta.rounded())
                maxOffLUT[k] = Int16(mx.rounded())

                guard delta >= 1.0 else {
                    hueMask[k] = 0
                    continue
                }

                var hue: Double
                if mx == dr {
                    hue = 60.0 * ((dg - db) / delta)
                    if hue < 0 { hue += 360.0 }
                } else if mx == dg {
                    hue = 60.0 * ((db - dr) / delta + 2.0)
                } else {
                    hue = 60.0 * ((dr - dg) / delta + 4.0)
                }

                let inRange: Bool
                if lowerHueWraps {
                    inRange = hue >= lowerHue || hue <= upperHue
                } else {
                    inRange = hue >= lowerHue && hue <= upperHue
                }
                hueMask[k] = inRange ? 1 : 0
            }
        }
    }

    // MARK: - Detection

    /// Run the detector on one 4:2:0 full-range bi-planar frame.
    ///
    /// - Parameters:
    ///   - luma: plane 0 base address.
    ///   - lumaStride: plane 0 bytes per row.
    ///   - chroma: plane 1 base address (Cb and Cr interleaved, one pair per
    ///     2x2 luma block).
    ///   - chromaStride: plane 1 bytes per row.
    /// - Parameter roiOverride: normalised ROI for this call. Pass `nil` to use
    ///   the ROI in `Config`.
    func detect(
        luma: UnsafePointer<UInt8>,
        lumaStride: Int,
        chroma: UnsafePointer<UInt8>,
        chromaStride: Int,
        width: Int,
        height: Int,
        roi roiOverride: CGRect? = nil
    ) -> [BallDetection] {
        let cfg = config
        guard width >= 8, height >= 8, lumaStride > 0, chromaStride > 0 else { return [] }
        let roi = roiOverride ?? cfg.roi

        // ROI, snapped to the 2x2 chroma grid.
        var x0 = Int((roi.minX * CGFloat(width)).rounded(.down))
        var y0 = Int((roi.minY * CGFloat(height)).rounded(.down))
        let x1 = min(width, Int((roi.maxX * CGFloat(width)).rounded(.up)))
        let y1 = min(height, Int((roi.maxY * CGFloat(height)).rounded(.up)))
        x0 = max(0, x0) & ~1
        y0 = max(0, y0) & ~1
        let roiW = (x1 - x0) & ~1
        let roiH = (y1 - y0) & ~1
        guard roiW >= 4, roiH >= 4 else { return [] }

        var cell = max(8, cfg.cellSizePx)
        if !cell.isPowerOfTwo { cell = 16 }
        let cellShift = cell.trailingZeroBitCount
        let gw = (roiW + cell - 1) >> cellShift
        let gh = (roiH + cell - 1) >> cellShift
        let cellCount = gw * gh

        scratch.ensure(cellCount)
        let counts = scratch.counts
        let sumX = scratch.sumX
        let sumY = scratch.sumY
        let minX = scratch.minX
        let maxX = scratch.maxX
        let minY = scratch.minY
        let maxY = scratch.maxY
        let parent = scratch.parent

        counts.update(repeating: 0, count: cellCount)
        sumX.update(repeating: 0, count: cellCount)
        sumY.update(repeating: 0, count: cellCount)
        minX.update(repeating: Int32.max, count: cellCount)
        maxX.update(repeating: -1, count: cellCount)
        minY.update(repeating: Int32.max, count: cellCount)
        maxY.update(repeating: -1, count: cellCount)

        let sMin = max(0, min(255, cfg.hsvLower.s))
        let vMin = max(0, min(255, cfg.hsvLower.v))
        let vMax = max(0, min(255, cfg.hsvUpper.v))

        // MARK: pass 1 - threshold, accumulate per cell

        let yEnd = y0 + roiH
        let xEnd = x0 + roiW
        var y = y0
        while y < yEnd {
            let lumaTop = luma + y * lumaStride
            let lumaBottom = lumaTop + lumaStride
            let chromaRow = chroma + (y >> 1) * chromaStride
            let cellRowBase = ((y - y0) >> cellShift) * gw

            var x = x0
            while x < xEnd {
                let cb = Int(chromaRow[x])
                let cr = Int(chromaRow[x + 1])
                let lutIndex = ((cb >> 2) << Self.lutShift) | (cr >> 2)

                if hueMask[lutIndex] != 0 {
                    let delta = Int(deltaLUT[lutIndex])
                    let maxOff = Int(maxOffLUT[lutIndex])
                    let cellIndex = cellRowBase + ((x - x0) >> cellShift)

                    // A pixel is a ball pixel when its own luminance is
                    // consistent with a saturated colour of this chroma:
                    //   V = Y + maxOff  (per-channel max, Offset added back)
                    //   S = delta / V
                    @inline(__always)
                    func passes(_ value: UInt8) -> Bool {
                        let v = Int(value) + maxOff
                        guard v >= vMin, v <= vMax else { return false }
                        return delta * 255 >= sMin * v
                    }

                    @inline(__always)
                    func store(_ px: Int, _ py: Int) {
                        counts[cellIndex] += 1
                        sumX[cellIndex] += Int32(px)
                        sumY[cellIndex] += Int32(py)
                        let px32 = Int32(px)
                        let py32 = Int32(py)
                        if px32 < minX[cellIndex] { minX[cellIndex] = px32 }
                        if px32 > maxX[cellIndex] { maxX[cellIndex] = px32 }
                        if py32 < minY[cellIndex] { minY[cellIndex] = py32 }
                        if py32 > maxY[cellIndex] { maxY[cellIndex] = py32 }
                    }

                    if passes(lumaTop[x]) { store(x, y) }
                    if passes(lumaTop[x + 1]) { store(x + 1, y) }
                    if passes(lumaBottom[x]) { store(x, y + 1) }
                    if passes(lumaBottom[x + 1]) { store(x + 1, y + 1) }
                }

                x += 2
            }
            y += 2
        }

        // MARK: pass 2 - 8-connected grouping on the cell grid

        for i in 0..<cellCount { parent[i] = Int32(i) }

        @inline(__always)
        func find(_ start: Int) -> Int {
            var root = start
            while parent[root] != Int32(root) { root = Int(parent[root]) }
            var node = start
            while parent[node] != Int32(node) {
                let next = Int(parent[node])
                parent[node] = Int32(root)
                node = next
            }
            return root
        }

        @inline(__always)
        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[max(ra, rb)] = Int32(min(ra, rb)) }
        }

        for cy in 0..<gh {
            let row = cy * gw
            for cx in 0..<gw {
                let i = row + cx
                guard counts[i] > 0 else { continue }
                if cx > 0, counts[i - 1] > 0 { union(i, i - 1) }
                if cy > 0 {
                    let up = i - gw
                    if counts[up] > 0 { union(i, up) }
                    if cx > 0, counts[up - 1] > 0 { union(i, up - 1) }
                    if cx + 1 < gw, counts[up + 1] > 0 { union(i, up + 1) }
                }
            }
        }

        // Fold each component into its root cell. Roots are never cleared, and
        // after path compression every non-root points straight at its root, so
        // a single ascending sweep cannot lose an accumulator.
        for i in 0..<cellCount where counts[i] > 0 {
            let root = find(i)
            if root == i { continue }
            counts[root] += counts[i]
            counts[i] = 0
            sumX[root] += sumX[i]
            sumY[root] += sumY[i]
            if minX[i] < minX[root] { minX[root] = minX[i] }
            if maxX[i] > maxX[root] { maxX[root] = maxX[i] }
            if minY[i] < minY[root] { minY[root] = minY[i] }
            if maxY[i] > maxY[root] { maxY[root] = maxY[i] }
        }

        // MARK: pass 3 - geometry per component

        let minArea = max(1, Int(cfg.minAreaPx.rounded(.up)))
        let minRadius = max(0.0, cfg.minRadiusPx)
        let maxRadius = max(minRadius, cfg.maxRadiusPx)
        let pi = Double.pi

        var found: [BallDetection] = []
        for i in 0..<cellCount where counts[i] > 0 {
            let area = Int(counts[i])
            guard area >= minArea else { continue }

            let radius = (Double(area) / pi).squareRoot()
            guard radius >= minRadius, radius <= maxRadius else { continue }

            let boxW = Int(maxX[i] - minX[i] + 1)
            let boxH = Int(maxY[i] - minY[i] + 1)
            guard boxW > 0, boxH > 0 else { continue }

            let longSide = Double(max(boxW, boxH))
            let shortSide = Double(min(boxW, boxH))
            let fill = Double(area) / (pi * (longSide / 2.0) * (longSide / 2.0))
            let aspect = shortSide / longSide
            let shape = max(0.0, min(1.0, min(fill, aspect)))

            guard shape >= cfg.minCircularity, shape >= cfg.minConfidence else { continue }

            let n = Double(area)
            found.append(
                BallDetection(
                    u: Float(Double(sumX[i]) / n),
                    v: Float(Double(sumY[i]) / n),
                    radius: Float(radius),
                    confidence: Float(shape),
                    area: area
                )
            )
        }

        // Largest / most disc-like first, same preference as the Python
        // detector (which sorts by confidence).
        found.sort { lhs, rhs in
            if lhs.confidence == rhs.confidence { return lhs.area > rhs.area }
            return lhs.confidence > rhs.confidence
        }
        let limit = max(0, cfg.maxCandidates)
        if found.count > limit { found.removeLast(found.count - limit) }
        return found
    }
}

// MARK: - Scratch buffers

/// Reusable per-frame scratch for the cell grid, so the hot path never
/// allocates. All eight regions live in one allocation.
private final class DetectorScratch {
    private static let regions = 8

    private var storage: UnsafeMutablePointer<Int32>
    private var capacity: Int

    init() {
        capacity = 1
        storage = .allocate(capacity: Self.regions)
        storage.initialize(repeating: 0, count: Self.regions)
    }

    deinit {
        storage.deallocate()
    }

    /// Grow (never shrink) so eight regions of `cells` Int32 fit.
    func ensure(_ cells: Int) {
        guard cells > capacity else { return }
        storage.deallocate()
        capacity = max(cells, capacity * 2)
        storage = .allocate(capacity: capacity * Self.regions)
    }

    var counts: UnsafeMutablePointer<Int32> { storage }
    var sumX: UnsafeMutablePointer<Int32> { storage + capacity }
    var sumY: UnsafeMutablePointer<Int32> { storage + capacity * 2 }
    var minX: UnsafeMutablePointer<Int32> { storage + capacity * 3 }
    var maxX: UnsafeMutablePointer<Int32> { storage + capacity * 4 }
    var minY: UnsafeMutablePointer<Int32> { storage + capacity * 5 }
    var maxY: UnsafeMutablePointer<Int32> { storage + capacity * 6 }
    var parent: UnsafeMutablePointer<Int32> { storage + capacity * 7 }
}

private extension Int {
    var isPowerOfTwo: Bool { self > 0 && self & (self - 1) == 0 }
}
