import Foundation
import Observation
import RacketKit
import SwiftData

/// Builds the facts the coach talks about. Shared by the template coach and Muse.
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

/// Something that can turn stats into words: Muse or the built-in template fallback.
@MainActor
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

/// Deterministic offline coach, available without an API key or network connection.
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
    var isWorking = false
    private(set) var hasMuseKey: Bool
    private(set) var lastEngineName: String?
    private(set) var lastFallbackReason: String?
    var engineName: String { lastEngineName ?? (museEnabled && hasMuseKey ? "Muse Spark · online" : fallback.name) }
    var museEnabled: Bool {
        didSet { UserDefaults.standard.set(museEnabled, forKey: "coach.museEnabled"); lastEngineName = nil }
    }
    @ObservationIgnored private weak var app: AppModel?
    private let fallback = TemplateCoach()
    @ObservationIgnored private let keyProvider: @MainActor () -> String?
    @ObservationIgnored private let clientFactory: @MainActor (String) -> MuseTransport

    init(keyProvider: @escaping @MainActor () -> String? = { MuseKeychain.read() },
         clientFactory: @escaping @MainActor (String) -> MuseTransport = { MuseClient(apiKey: $0) }) {
        self.keyProvider = keyProvider
        self.clientFactory = clientFactory
        hasMuseKey = keyProvider()?.isEmpty == false
        museEnabled = UserDefaults.standard.bool(forKey: "coach.museEnabled")
    }

    func connect(to app: AppModel) { self.app = app }

    func saveMuseKey(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MuseError.noKey }
        try MuseKeychain.save(key)
        hasMuseKey = true
        museEnabled = true
    }

    func removeMuseKey() throws {
        try MuseKeychain.delete()
        hasMuseKey = false
        museEnabled = false
    }

    func summarize(_ session: SessionRecord) async -> String {
        let digest = SessionDigest(session: session)
        return await run(session: session) { try await $0.summarize(digest) }
    }

    func answer(_ q: String, session: SessionRecord) async -> String {
        let digest = SessionDigest(session: session)
        return await run(session: session) { try await $0.answer(q, digest: digest) }
    }

    func drill(_ session: SessionRecord) async -> String {
        let digest = SessionDigest(session: session)
        return await run(session: session) { try await $0.drill(digest) }
    }

    private func run(session: SessionRecord, _ body: (CoachEngine) async throws -> String) async -> String {
        guard !isWorking else { return "The coach is already answering. Please try again shortly." }
        isWorking = true
        lastFallbackReason = nil
        defer { isWorking = false }
        if museEnabled, let key = keyProvider(), !key.isEmpty {
            let app = self.app
            let tools = CoachTools(current: session, app: app) {
                guard let context = app?.modelContext else { return [session] }
                return try context.fetch(FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.startDate)]))
            }
            let muse = MuseCoach(client: clientFactory(key), tools: tools)
            do {
                let text = try await body(muse)
                lastEngineName = muse.name
                return text
            } catch {
                if Task.isCancelled { return "Coaching cancelled." }
                lastFallbackReason = error.localizedDescription
            }
        }
        lastEngineName = fallback.name
        return (try? await body(fallback)) ?? "The coach is unavailable right now."
    }
}
