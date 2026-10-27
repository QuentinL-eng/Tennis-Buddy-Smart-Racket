import Foundation
import Observation
import RacketKit

/// Builds the facts the coach talks about. Shared by the template coach and Llama.
struct SessionDigest: Codable {
    struct Stroke: Codable {
        var type: String
        var count: Int
        var sweetSpotPercent: Int
        var avgBallSpeed: Int
        var maxBallSpeed: Int
        var avgSwingSpeed: Int
        var avgSpinRPM: Int
        var avgPathDeg: Int
        var avgFaceDeg: Int
        var avgContactTowardTip: Double
        var avgContactRight: Double
        var contactSpread: Double
    }

    var speedUnit: String
    var lengthUnit: String
    var durationMinutes: Int
    var totalShots: Int
    var sweetSpotPercent: Int
    var pointsWon: Int
    var pointsLost: Int
    var averageHeartRate: Int
    var strokes: [Stroke]
    /// Ball speed in the first vs last third of the session (fatigue).
    var firstThirdAvgSpeed: Int
    var lastThirdAvgSpeed: Int

    init(session: SessionRecord, units: UnitSystem = .current) {
        speedUnit = units.speedUnit
        lengthUnit = units.lengthUnit
        func spd(_ kmh: Double) -> Int { Int(units.speed(kmh).rounded()) }
        func len(_ cm: Double) -> Double { (units.length(cm) * 10).rounded() / 10 }
        let shots = session.shots.filter { $0.type != .calibration }
        let all = ShotSummary(shots)
        durationMinutes = Int(session.duration / 60)
        totalShots = shots.count
        sweetSpotPercent = Int(all.sweetSpotPercent)
        pointsWon = session.pointsWon
        pointsLost = session.pointsLost
        averageHeartRate = Int(session.averageHeartRate)
        strokes = ShotType.allCases.compactMap { t in
            let s = shots.filter { $0.type == t }
            guard !s.isEmpty else { return nil }
            let m = ShotSummary(s)
            return Stroke(type: t.label, count: m.count, sweetSpotPercent: Int(m.sweetSpotPercent),
                          avgBallSpeed: spd(m.avgBallKmh), maxBallSpeed: spd(m.maxBallKmh), avgSwingSpeed: spd(m.avgSwingKmh),
                          avgSpinRPM: Int(m.avgSpinRPM), avgPathDeg: Int(m.avgPathAngle), avgFaceDeg: Int(m.avgFaceAngle),
                          avgContactTowardTip: len(m.avgImpactY),
                          avgContactRight: len(m.avgImpactX),
                          contactSpread: len(m.impactSpreadCm))
        }
        let third = max(shots.count / 3, 1)
        firstThirdAvgSpeed = spd(ShotSummary(Array(shots.prefix(third))).avgBallKmh)
        lastThirdAvgSpeed = spd(ShotSummary(Array(shots.suffix(third))).avgBallKmh)
    }

    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }
}

/// Something that can turn stats into words: Llama on device, or the built-in template fallback.
protocol CoachEngine {
    var name: String { get }
    func summarize(_ digest: SessionDigest) async throws -> String
    func answer(_ question: String, digest: SessionDigest) async throws -> String
    func drill(_ digest: SessionDigest) async throws -> String
}

enum CoachPrompts {
    static let system = """
    You are Tennis Buddy, an upbeat, expert tennis coach. You are given measurements from a sensor in the \
    player's racket. Only use numbers that appear in the data; never invent stats. Speeds use the data's speedUnit, \
    spin is rpm, contact positions use lengthUnit from the sweet spot (positive toward the tip / to the right). \
    Always write the units next to numbers and never mention JSON field names. Keep answers short, \
    concrete and encouraging.
    """

    static func summary(_ d: SessionDigest) -> String {
        """
        Session data:
        \(d.json)

        Write a session report in under 120 words, no greeting. Start with one sentence on the overall session. \
        Then name the strongest stroke with two of its numbers and the weakest area with two of its numbers. \
        End with exactly 2 bullet-point tips. Each tip must cite a number from the data and give one concrete \
        technique cue (for example contact point, footwork, swing path or racket face). No generic advice.
        """
    }

    static func question(_ q: String, _ d: SessionDigest) -> String {
        "Session data:\n\(d.json)\n\nPlayer's question: \(q)\nAnswer in under 80 words using the data."
    }

    static func drill(_ d: SessionDigest) -> String {
        """
        Session data:
        \(d.json)

        Design ONE short drill for the player's weakest stroke. Reply with exactly these three lines and nothing else:
        TITLE: <2 to 5 words>
        GOAL: <a number from 5 to 15> <stroke name in plural> <condition>
        WHY: <one sentence that cites one number from the data, with its unit>
        The condition must be exactly one of: "in the sweet spot", "over <number> rpm", "over <number> \(d.speedUnit)".
        Never mention data field names. Example:
        TITLE: Center the backhand
        GOAL: 10 backhands in the sweet spot
        WHY: Only 35% of your backhands hit the sweet spot.
        """
    }
}

/// Deterministic coach used when Llama isn't loaded, so the feature always works.
struct TemplateCoach: CoachEngine {
    let name = "Built-in coach"

    func summarize(_ d: SessionDigest) async throws -> String {
        guard d.totalShots > 0 else { return "No shots recorded yet. Start a session and hit a few balls." }
        let best = d.strokes.max { $0.sweetSpotPercent < $1.sweetSpotPercent }
        let worst = d.strokes.min { $0.sweetSpotPercent < $1.sweetSpotPercent }
        var out = "\(d.totalShots) shots in \(max(d.durationMinutes, 1)) min with \(d.sweetSpotPercent)% in the sweet spot. "
        if let b = best {
            out += "Your \(b.type.lowercased()) led the way: \(b.sweetSpotPercent)% sweet spot, averaging \(b.avgBallSpeed) \(d.speedUnit) (top \(b.maxBallSpeed)). "
        }
        if let w = worst, w.type != best?.type {
            let dir = w.avgContactTowardTip >= 0 ? "toward the tip" : "toward the throat"
            out += "Your \(w.type.lowercased()) needs work: \(w.sweetSpotPercent)% sweet spot, contact drifting \(String(format: "%.1f", abs(w.avgContactTowardTip))) \(d.lengthUnit) \(dir). "
        }
        out += "\n\n• "
        if d.lastThirdAvgSpeed < d.firstThirdAvgSpeed - 3 {
            out += "Ball speed dropped from \(d.firstThirdAvgSpeed) to \(d.lastThirdAvgSpeed) \(d.speedUnit) late in the session; take short breaks to keep your legs fresh."
        } else {
            out += "You kept your pace all session (\(d.firstThirdAvgSpeed) → \(d.lastThirdAvgSpeed) \(d.speedUnit)). Nice consistency."
        }
        if let w = worst {
            out += "\n• On your \(w.type.lowercased()), "
            let near = d.lengthUnit == "cm" ? 1.0 : 0.4
            out += w.avgContactTowardTip > near ? "let the ball come a little deeper so you meet it in the center of the strings."
                : w.avgContactTowardTip < -near ? "step in and reach a little further so contact moves up toward the center."
                : "keep your eyes on contact a beat longer to tighten your \(w.contactSpread) \(d.lengthUnit) spread."
        }
        return out
    }

    func answer(_ question: String, digest d: SessionDigest) async throws -> String {
        let q = question.lowercased()
        if let s = d.strokes.first(where: { q.contains($0.type.lowercased()) }) {
            return "\(s.type): \(s.count) shots, \(s.sweetSpotPercent)% sweet spot, \(s.avgBallSpeed) \(d.speedUnit) average (top \(s.maxBallSpeed)), \(s.avgSpinRPM) rpm, swing path \(s.avgPathDeg)°."
        }
        return try await summarize(d)
    }

    func drill(_ d: SessionDigest) async throws -> String {
        let w = d.strokes.min { $0.sweetSpotPercent < $1.sweetSpotPercent }
        let stroke = w?.type ?? "Forehand"
        return "TITLE: Center the \(stroke)\nGOAL: 10 \(stroke.lowercased())s in the sweet spot\nWHY: Only \(w?.sweetSpotPercent ?? 0)% of your \(stroke.lowercased())s hit the sweet spot."
    }
}

@MainActor
@Observable
final class CoachModel {
    enum ModelState: Equatable { case notLoaded, downloading(Double), loading, ready, failed(String) }

    var state: ModelState = .notLoaded
    var engineName: String { llama?.name ?? TemplateCoach().name }
    var isWorking = false
    private var llama: CoachEngine?
    private let fallback = TemplateCoach()
    private var engine: CoachEngine { llama ?? fallback }

    func loadLlama() async {
        guard llama == nil, state != .loading else { return }
        state = .loading
        do {
            llama = try await LlamaLoader.load { [weak self] progress in
                Task { @MainActor in self?.state = .downloading(progress) }
            }
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func summarize(_ session: SessionRecord) async -> String {
        await run { try await $0.summarize(SessionDigest(session: session)) }
    }

    func answer(_ q: String, session: SessionRecord) async -> String {
        await run { try await $0.answer(q, digest: SessionDigest(session: session)) }
    }

    func drill(_ session: SessionRecord) async -> String {
        await run { try await $0.drill(SessionDigest(session: session)) }
    }

    private func run(_ body: (CoachEngine) async throws -> String) async -> String {
        isWorking = true
        defer { isWorking = false }
        do { return try await body(engine) } catch {
            return (try? await body(fallback)) ?? "The coach is unavailable right now."
        }
    }
}
