import Foundation

/// A short practice goal ("10 forehands in the sweet spot") that counts down as matching shots land.
/// Created from the coach's drill text, tracked on the iPhone/Mac, mirrored on the Watch.
public struct Drill: Codable, Sendable, Equatable, Identifiable {
    public enum Criterion: Codable, Sendable, Equatable {
        case sweetSpot
        case minSpinRPM(Double)
        case minBallKmh(Double)
        case any
    }

    public var id = UUID()
    public var title: String
    public var goal: String
    public var why: String
    public var target: Int
    public var stroke: ShotType?
    public var criterion: Criterion
    public var completed = 0

    public init(title: String, goal: String, why: String, target: Int, stroke: ShotType?, criterion: Criterion) {
        self.title = title
        self.goal = goal
        self.why = why
        self.target = target
        self.stroke = stroke
        self.criterion = criterion
    }

    public var remaining: Int { max(0, target - completed) }
    public var isDone: Bool { completed >= target }
    public var progress: Double { target > 0 ? min(1, Double(completed) / Double(target)) : 0 }

    public func matches(_ shot: ShotMetrics) -> Bool {
        if let stroke, shot.type != stroke { return false }
        switch criterion {
        case .sweetSpot: return shot.isSweetSpot
        case .minSpinRPM(let rpm): return shot.spinRPM >= rpm
        case .minBallKmh(let kmh): return shot.ballSpeedKmh >= kmh
        case .any: return true
        }
    }

    /// Parses the coach's reply ("TITLE: …\nGOAL: 10 forehands in the sweet spot\nWHY: …").
    /// Tolerant of small format drifts; defaults to "sweet spot" when no number condition is found.
    public static func parse(_ text: String) -> Drill {
        func field(_ name: String) -> String? {
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
                if trimmed.uppercased().hasPrefix(name + ":") {
                    return String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }
        let goal = field("GOAL") ?? text
        let lower = goal.lowercased()
        let numbers = lower.matches(of: #/(\d+(?:\.\d+)?)/#).compactMap { Double($0.output.1) }
        let target = max(1, min(50, Int(numbers.first ?? 10)))
        let stroke = ShotType.allCases.first { lower.contains($0.rawValue) && $0 != .calibration }

        var criterion: Criterion = .sweetSpot
        let threshold = numbers.dropFirst().first
        if let threshold, lower.contains("rpm") {
            criterion = .minSpinRPM(threshold)
        } else if let threshold, lower.contains("mph") {
            criterion = .minBallKmh(threshold * 1.609344)
        } else if let threshold, lower.contains("km/h") || lower.contains("kph") {
            criterion = .minBallKmh(threshold)
        } else if !lower.contains("sweet") && !lower.contains("center") {
            criterion = .any
        }
        return Drill(title: field("TITLE") ?? "Next drill", goal: goal, why: field("WHY") ?? "", target: target,
                     stroke: stroke, criterion: criterion)
    }
}
