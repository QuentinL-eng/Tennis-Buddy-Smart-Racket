import Foundation
import Observation
import RacketKit

/// Builds the facts the coach talks about. Shared by the template coach and Gemma.
struct SessionDigest: Codable {
    struct Stroke: Codable {
        var type: String
        var count: Int
        var sweetSpotPercent: Int
        var avgBallKmh: Int
        var maxBallKmh: Int
        var avgSwingKmh: Int
        var avgSpinRPM: Int
        var avgPathDeg: Int
        var avgFaceDeg: Int
        var avgContactTowardTipCm: Double
        var avgContactRightCm: Double
        var contactSpreadCm: Double
    }

    var durationMinutes: Int
    var totalShots: Int
    var sweetSpotPercent: Int
    var pointsWon: Int
    var pointsLost: Int
    var strokes: [Stroke]
    /// Ball speed in the first vs last third of the session (fatigue).
    var firstThirdAvgKmh: Int
    var lastThirdAvgKmh: Int

    init(session: SessionRecord) {
        let shots = session.shots.filter { $0.type != .calibration }
        let all = ShotSummary(shots)
        durationMinutes = Int(session.duration / 60)
        totalShots = shots.count
        sweetSpotPercent = Int(all.sweetSpotPercent)
        pointsWon = session.pointsWon
        pointsLost = session.pointsLost
        strokes = ShotType.allCases.compactMap { t in
            let s = shots.filter { $0.type == t }
            guard !s.isEmpty else { return nil }
            let m = ShotSummary(s)
            return Stroke(type: t.label, count: m.count, sweetSpotPercent: Int(m.sweetSpotPercent),
                          avgBallKmh: Int(m.avgBallKmh), maxBallKmh: Int(m.maxBallKmh), avgSwingKmh: Int(m.avgSwingKmh),
                          avgSpinRPM: Int(m.avgSpinRPM), avgPathDeg: Int(m.avgPathAngle), avgFaceDeg: Int(m.avgFaceAngle),
                          avgContactTowardTipCm: (m.avgImpactY * 10).rounded() / 10,
                          avgContactRightCm: (m.avgImpactX * 10).rounded() / 10,
                          contactSpreadCm: (m.impactSpreadCm * 10).rounded() / 10)
        }
        let third = max(shots.count / 3, 1)
        firstThirdAvgKmh = Int(ShotSummary(Array(shots.prefix(third))).avgBallKmh)
        lastThirdAvgKmh = Int(ShotSummary(Array(shots.suffix(third))).avgBallKmh)
    }

    var json: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: (try? enc.encode(self)) ?? Data(), encoding: .utf8) ?? "{}"
    }
}

/// Something that can turn stats into words: Gemma on device, or the built-in template fallback.
protocol CoachEngine {
    var name: String { get }
    func summarize(_ digest: SessionDigest) async throws -> String
    func answer(_ question: String, digest: SessionDigest) async throws -> String
    func drill(_ digest: SessionDigest) async throws -> String
}

enum CoachPrompts {
    static let system = """
    You are Tennis Buddy, an upbeat, expert tennis coach. You are given measurements from a sensor in the \
    player's racket. Only use numbers that appear in the data; never invent stats. Speeds are km/h, spin is rpm, \
    contact positions are cm from the sweet spot (positive toward the tip / to the right). Keep answers short, \
    concrete and encouraging.
    """

    static func summary(_ d: SessionDigest) -> String {
        """
        Session data:
        \(d.json)

        Write a session report in under 120 words: one sentence on the overall session, the strongest stroke \
        with its numbers, the weakest area with its numbers, then exactly 2 specific tips as bullet points.
        """
    }

    static func question(_ q: String, _ d: SessionDigest) -> String {
        "Session data:\n\(d.json)\n\nPlayer's question: \(q)\nAnswer in under 80 words using the data."
    }

    static func drill(_ d: SessionDigest) -> String {
        """
        Session data:
        \(d.json)

        Design ONE short drill targeting the weakest area. Reply in exactly this format:
        TITLE: <max 5 words>
        GOAL: <count> <stroke> <condition with a number>
        WHY: <one sentence citing a number>
        """
    }
}

/// Deterministic coach used when Gemma isn't loaded, so the feature always works.
struct TemplateCoach: CoachEngine {
    let name = "Built-in coach"

    func summarize(_ d: SessionDigest) async throws -> String {
        guard d.totalShots > 0 else { return "No shots recorded yet. Start a session and hit a few balls." }
        let best = d.strokes.max { $0.sweetSpotPercent < $1.sweetSpotPercent }
        let worst = d.strokes.min { $0.sweetSpotPercent < $1.sweetSpotPercent }
        var out = "\(d.totalShots) shots in \(max(d.durationMinutes, 1)) min with \(d.sweetSpotPercent)% in the sweet spot. "
        if let b = best {
            out += "Your \(b.type.lowercased()) led the way: \(b.sweetSpotPercent)% sweet spot, averaging \(b.avgBallKmh) km/h (top \(b.maxBallKmh)). "
        }
        if let w = worst, w.type != best?.type {
            let dir = w.avgContactTowardTipCm >= 0 ? "toward the tip" : "toward the throat"
            out += "Your \(w.type.lowercased()) needs work: \(w.sweetSpotPercent)% sweet spot, contact drifting \(String(format: "%.1f", abs(w.avgContactTowardTipCm))) cm \(dir). "
        }
        out += "\n\n• "
        if d.lastThirdAvgKmh < d.firstThirdAvgKmh - 5 {
            out += "Ball speed dropped from \(d.firstThirdAvgKmh) to \(d.lastThirdAvgKmh) km/h late in the session; take short breaks to keep your legs fresh."
        } else {
            out += "You kept your pace all session (\(d.firstThirdAvgKmh) → \(d.lastThirdAvgKmh) km/h). Nice consistency."
        }
        if let w = worst {
            out += "\n• On your \(w.type.lowercased()), "
            out += w.avgContactTowardTipCm > 1 ? "let the ball come a little deeper so you meet it in the center of the strings."
                : w.avgContactTowardTipCm < -1 ? "step in and reach a little further so contact moves up toward the center."
                : "keep your eyes on contact a beat longer to tighten your \(w.contactSpreadCm) cm spread."
        }
        return out
    }

    func answer(_ question: String, digest d: SessionDigest) async throws -> String {
        let q = question.lowercased()
        if let s = d.strokes.first(where: { q.contains($0.type.lowercased()) }) {
            return "\(s.type): \(s.count) shots, \(s.sweetSpotPercent)% sweet spot, \(s.avgBallKmh) km/h average (top \(s.maxBallKmh)), \(s.avgSpinRPM) rpm, swing path \(s.avgPathDeg)°."
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
    var engineName: String { gemma?.name ?? TemplateCoach().name }
    var isWorking = false
    private var gemma: CoachEngine?
    private let fallback = TemplateCoach()
    private var engine: CoachEngine { gemma ?? fallback }

    func loadGemma() async {
        guard gemma == nil else { return }
        do {
            gemma = try await GemmaLoader.load { [weak self] progress in
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
