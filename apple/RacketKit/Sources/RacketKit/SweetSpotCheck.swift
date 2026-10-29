import Foundation

/// Ground-truth check of the racket's on-device sweet-spot model: balls dropped on known squares of a taped 3×3
/// grid, each paired with the verdict the racket sent and the app's motion-sensor estimate for the same hit.
/// The center square is the sweet spot; every other square is 5 to 8 cm off it, outside `sweetSpotRadiusCm`.
public struct SweetSpotCheck: Sendable {
    public struct Cell: Hashable, Codable, Sendable {
        public var col: Int   // -1 left, 0 center, 1 right
        public var row: Int   // 1 tip, 0 center, -1 throat
        public init(col: Int, row: Int) { self.col = col; self.row = row }

        /// Taped square spacing: 5 cm across the face, 6 cm along it.
        public var xCm: Double { Double(col) * 5 }
        public var yCm: Double { Double(row) * 6 }
        public var distanceCm: Double { (xCm * xCm + yCm * yCm).squareRoot() }
        public var isSweet: Bool { distanceCm <= ShotMetrics.sweetSpotRadiusCm }
        public var name: String {
            if col == 0 && row == 0 { return "center" }
            let r = row > 0 ? "tip" : (row < 0 ? "throat" : "")
            let c = col < 0 ? "left" : (col > 0 ? "right" : "")
            return [r, c].filter { !$0.isEmpty }.joined(separator: "-")
        }
    }

    public struct Drop: Codable, Sendable, Identifiable {
        public var id = UUID()
        public var date: Date
        public var cell: Cell
        /// The racket's verdict; nil if none arrived (simulator, or a mic that missed the hit).
        public var racketSweet: Bool?
        public var offCenterPercent: Int?
        public var confidencePercent: Int?
        public var level: Int?
        /// The app's motion-sensor estimate; nil if the IMU didn't register the hit.
        public var imuXcm: Double?
        public var imuYcm: Double?
        public var peakG: Double?
        public var features: ImpactFeatures?

        /// Whether the racket's verdict matched the square; nil without a verdict.
        public var racketCorrect: Bool? { racketSweet.map { $0 == cell.isSweet } }
    }

    /// A verdict and an IMU impact this close together, on the same square, are one drop.
    public static let pairWindow: TimeInterval = 0.6

    public private(set) var drops: [Drop] = []

    public init() {}

    public mutating func add(verdict v: RacketProtocol.ShotVerdict, cell: Cell, at date: Date = Date()) {
        let i = pairIndex(cell: cell, date: date) { $0.racketSweet == nil } ?? newDrop(cell: cell, date: date)
        drops[i].racketSweet = v.isSweet
        drops[i].offCenterPercent = v.offCenterPercent
        drops[i].confidencePercent = v.confidencePercent
        drops[i].level = v.level
    }

    public mutating func add(shot: ShotMetrics, cell: Cell, at date: Date = Date()) {
        guard shot.micOnly != true else { return }
        let i = pairIndex(cell: cell, date: date) { $0.features == nil } ?? newDrop(cell: cell, date: date)
        drops[i].imuXcm = shot.impactXcm
        drops[i].imuYcm = shot.impactYcm
        drops[i].peakG = shot.peakG
        drops[i].features = shot.features
    }

    public mutating func undo() { if !drops.isEmpty { drops.removeLast() } }

    public func drops(in cell: Cell) -> [Drop] { drops.filter { $0.cell == cell } }

    /// Drops the racket gave a verdict on, and how many of those it got right.
    public var scored: Int { drops.filter { $0.racketSweet != nil }.count }
    public var correct: Int { drops.filter { $0.racketCorrect == true }.count }
    public var accuracy: Double? { scored > 0 ? Double(correct) / Double(scored) : nil }
    /// Sweet-spot drops the racket called sweet, and off-center drops it called off-center.
    public var sweetHits: (correct: Int, of: Int) { tally { $0.cell.isSweet } }
    public var offHits: (correct: Int, of: Int) { tally { !$0.cell.isSweet } }

    /// One row per drop, `dist_cm` as in the training `labels.csv`, for data/ and ml/.
    public func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
        func i(_ v: Int?) -> String { v.map(String.init) ?? "" }
        var out = "date,cell,col,row,x_cm,y_cm,dist_cm,expected_sweet,racket_sweet,racket_correct,off_center_pct,"
            + "confidence_pct,level,imu_x_cm,imu_y_cm,peak_g,roll_ratio,ring_norm,jolt,impulse\n"
        for d in drops {
            let ft = d.features
            let cols: [String] = [
                iso.string(from: d.date), d.cell.name, "\(d.cell.col)", "\(d.cell.row)",
                f(d.cell.xCm), f(d.cell.yCm), f(d.cell.distanceCm), d.cell.isSweet ? "1" : "0",
                d.racketSweet.map { $0 ? "1" : "0" } ?? "", d.racketCorrect.map { $0 ? "1" : "0" } ?? "",
                i(d.offCenterPercent), i(d.confidencePercent), i(d.level),
                f(d.imuXcm), f(d.imuYcm), f(d.peakG),
                f(ft.map { Double($0.rollRatio) }), f(ft.map { Double($0.ringNorm) }),
                f(ft.map { Double($0.jolt) }), f(ft.map { Double($0.impulse) }),
            ]
            out += cols.joined(separator: ",") + "\n"
        }
        return out
    }

    private func pairIndex(cell: Cell, date: Date, missing: (Drop) -> Bool) -> Int? {
        guard let i = drops.indices.last, drops[i].cell == cell, missing(drops[i]),
              abs(date.timeIntervalSince(drops[i].date)) <= Self.pairWindow else { return nil }
        return i
    }

    private mutating func newDrop(cell: Cell, date: Date) -> Int {
        drops.append(Drop(date: date, cell: cell))
        return drops.count - 1
    }

    private func tally(_ include: (Drop) -> Bool) -> (correct: Int, of: Int) {
        let d = drops.filter { include($0) && $0.racketSweet != nil }
        return (d.filter { $0.racketCorrect == true }.count, d.count)
    }
}
