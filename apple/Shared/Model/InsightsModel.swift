import Foundation
import RacketKit

enum InsightMetric: String, CaseIterable, Identifiable {
    case ballSpeed, swingSpeed, spin, face, path, contact, shots, heartRate, sweetSpot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ballSpeed: "Ball speed"; case .swingSpeed: "Swing speed"; case .spin: "Spin"
        case .face: "Face"; case .path: "Path"; case .contact: "Contact"
        case .shots: "Shots"; case .heartRate: "Heart rate"; case .sweetSpot: "Sweet spot"
        }
    }
    /// Metrics that have a per-shot value and so get a min–max range bar.
    var isPerShot: Bool { ![.shots, .heartRate, .sweetSpot].contains(self) }
    /// +1 = higher is better, -1 = lower is better, 0 = closer to zero is better, nil = no verdict.
    var betterDirection: Int? {
        switch self {
        case .ballSpeed, .swingSpeed, .shots, .sweetSpot: 1
        case .contact: -1
        case .face: 0
        case .spin, .path, .heartRate: nil
        }
    }
    func unit(_ u: UnitSystem) -> String {
        switch self {
        case .ballSpeed, .swingSpeed: u.speedUnit
        case .spin: "rpm"
        case .face, .path: "°"
        case .contact: u.lengthUnit
        case .shots: "shots"
        case .heartRate: "bpm"
        case .sweetSpot: "%"
        }
    }
    /// Value for one shot in display units. nil = this shot has no value for the metric.
    func value(_ s: ShotMetrics, _ u: UnitSystem) -> Double? {
        switch self {
        case .ballSpeed: s.hasMotion ? u.speed(s.ballSpeedKmh) : nil
        case .swingSpeed: s.hasMotion ? u.speed(s.swingSpeedKmh) : nil
        case .spin: s.hasMotion ? s.spinRPM : nil
        case .face: s.hasMotion ? s.faceAngleDeg : nil
        case .path: s.hasMotion ? s.swingPathDeg : nil
        case .contact: u.length(s.impactDistanceCm)
        case .shots, .heartRate, .sweetSpot: nil
        }
    }
}

enum InsightPeriod: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: "Last 7 days"; case .month: "Last 30 days"; case .quarter: "Last 90 days"
        case .year: "This year"; case .all: "All time"
        }
    }
    var days: Int? { switch self { case .week: 7; case .month: 30; case .quarter: 90; case .year: 365; case .all: nil } }
}

struct InsightSession: Identifiable {
    var id: UUID
    var date: Date
    var duration: TimeInterval
    var averageHeartRate: Double
    var shots: [ShotMetrics]
}

struct SessionPoint: Identifiable {
    var id: UUID; var date: Date
    var low: Double; var high: Double; var avg: Double
    var shotCount: Int; var duration: TimeInterval
}

struct InsightsModel {
    var sessions: [InsightSession]
    var period: InsightPeriod
    var stroke: ShotType?
    var metric: InsightMetric
    var units: UnitSystem
    var now = Date()

    private func window(previous: Bool) -> [InsightSession] {
        guard let days = period.days else { return previous ? [] : sessions }
        let length = TimeInterval(days) * 86_400
        let end = now.addingTimeInterval(previous ? -length : 0)
        let start = end.addingTimeInterval(-length)
        return sessions.filter { $0.date > start && $0.date <= end }
    }

    private func shots(_ s: InsightSession) -> [ShotMetrics] {
        s.shots.filter { $0.type != .calibration && (stroke == nil || $0.type == stroke) }
    }

    private func values(_ list: [InsightSession], _ metric: InsightMetric) -> [Double] {
        list.flatMap { shots($0).compactMap { metric.value($0, units) } }
    }

    /// One point per session with data for the current picks.
    var points: [SessionPoint] {
        window(previous: false).compactMap { s in
            let list = shots(s)
            guard !list.isEmpty else { return nil }
            switch metric {
            case .shots:
                let n = Double(list.count)
                return SessionPoint(id: s.id, date: s.date, low: n, high: n, avg: n, shotCount: list.count, duration: s.duration)
            case .heartRate:
                guard s.averageHeartRate > 0 else { return nil }
                let v = s.averageHeartRate
                return SessionPoint(id: s.id, date: s.date, low: v, high: v, avg: v, shotCount: list.count, duration: s.duration)
            case .sweetSpot:
                let v = Double(list.filter(\.isSweetSpot).count) / Double(list.count) * 100
                return SessionPoint(id: s.id, date: s.date, low: v, high: v, avg: v, shotCount: list.count, duration: s.duration)
            default:
                let v = list.compactMap { metric.value($0, units) }
                guard let lo = v.min(), let hi = v.max() else { return nil }
                return SessionPoint(id: s.id, date: s.date, low: lo, high: hi, avg: v.reduce(0, +) / Double(v.count),
                                    shotCount: list.count, duration: s.duration)
            }
        }
        .sorted { $0.date < $1.date }
    }

    /// Average for the period. Per-shot metrics average over shots; session-level metrics over sessions.
    var periodAverage: Double? { periodAverage(window(previous: false)) }

    private func periodAverage(_ list: [InsightSession]) -> Double? {
        if metric.isPerShot {
            let v = values(list, metric)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        let pts = SessionPointBuilder.points(list, self)
        return pts.isEmpty ? nil : pts.map(\.avg).reduce(0, +) / Double(pts.count)
    }

    var previousAverage: Double? { periodAverage(window(previous: true)) }
    var top: Double? { metric.isPerShot ? values(window(previous: false), metric).max() : nil }
    var low: Double? { metric.isPerShot ? values(window(previous: false), metric).min() : nil }
    var delta: Double? {
        guard let a = periodAverage, let b = previousAverage else { return nil }
        return a - b
    }

    /// Average of the metric per stroke; strokes with under 5 shots are skipped.
    var byStroke: [(type: ShotType, avg: Double)] {
        guard metric.isPerShot || metric == .sweetSpot else { return [] }
        let list = window(previous: false).flatMap { $0.shots }.filter { $0.type != .calibration }
        return [ShotType.forehand, .backhand, .serve, .volley].compactMap { t in
            let group = list.filter { $0.type == t }
            guard group.count >= 5 else { return nil }
            if metric == .sweetSpot { return (t, Double(group.filter(\.isSweetSpot).count) / Double(group.count) * 100) }
            let v = group.compactMap { metric.value($0, units) }
            return v.isEmpty ? nil : (t, v.reduce(0, +) / Double(v.count))
        }
    }

    var hasHeartRate: Bool { sessions.contains { $0.averageHeartRate > 0 } }
}

/// Builds session points for an arbitrary session list (used for the previous period).
private enum SessionPointBuilder {
    static func points(_ list: [InsightSession], _ m: InsightsModel) -> [SessionPoint] {
        var copy = m
        copy.sessions = list
        copy.period = .all
        return copy.points
    }
}
