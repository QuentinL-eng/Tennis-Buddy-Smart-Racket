import Foundation
import RacketKit
import SwiftData

/// All stored/live data access stays on the main actor. Tools are read-only.
@MainActor
final class CoachTools {
    private let sessions: () throws -> [SessionRecord]
    private weak var app: AppModel?
    private let current: SessionRecord
    let units: UnitSystem

    init(current: SessionRecord, app: AppModel?, units: UnitSystem = .current,
         sessions: @escaping () throws -> [SessionRecord]) {
        self.current = current; self.app = app; self.units = units; self.sessions = sessions
    }

    static let schemas: [[String: Any]] = {
        func string(_ description: String, values: [String]? = nil) -> [String: Any] {
            var p: [String: Any] = ["type": "string", "description": description]
            if let values { p["enum"] = values }
            return p
        }
        func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]]
        }
        let session = string("Session UUID from the digest catalog, or current/latest/previous. Defaults to current.")
        let type = string("Stroke filter. Omit for all non-calibration shots.", values: ShotType.allCases.filter { $0 != .calibration }.map(\.rawValue))
        return [
            tool("query_shots", "Aggregate stored shots in memory. Returns counts and an optional metric; unavailable motion metrics are null. Dates are inclusive ISO 8601 timestamps.",
                 ["session": string("UUID/current/latest/previous/all. Defaults to current."), "type": type,
                  "metric": string("Optional metric; omit for all aggregate metrics.", values: Array(metrics.keys).sorted()),
                  "from": string("Start ISO 8601 timestamp"), "to": string("End ISO 8601 timestamp")]),
            tool("compare_sessions", "Return digests for two sessions and b-minus-a aggregate differences in the stated units.",
                 ["a": session, "b": session], ["a", "b"]),
            tool("get_session_digest", "Return the session digest and a catalog of session IDs and dates. Health data and notes are excluded.", ["session": session]),
            tool("get_live_state", "Return the current source, connection state and last shot. Motion fields are absent for mic-only hits.", [:]),
            tool("simulate_change", "Estimate speed/spin effects on this player's mean motion-enabled shot. No flight, landing depth or net clearance is modeled. Proposed deltas and final inputs are clamped. Returns baseline and changed estimates, not measured outcomes.",
                 ["session": session, "type": type, "swing_percent": number("Swing speed delta percent, clamped to -30...30"),
                  "face_deg": number("Face angle delta degrees, clamped to -15...15"),
                  "path_deg": number("Path angle delta degrees, clamped to -15...15"),
                  "contact_x_cm": number("Contact x delta cm, clamped to -5...5"),
                  "contact_y_cm": number("Contact y delta cm, clamped to -5...5")])
        ]
    }()

    private static let metrics: [String: (unit: String, motion: Bool, value: (ShotMetrics) -> Double)] = [
        "ball_speed": ("speed", true, { $0.ballSpeedKmh }), "swing_speed": ("speed", true, { $0.swingSpeedKmh }),
        "spin": ("rpm", true, { $0.spinRPM }), "face_angle": ("degrees", true, { $0.faceAngleDeg }),
        "path_angle": ("degrees", true, { $0.swingPathDeg }),
        "contact_x": ("length", true, { $0.impactXcm }), "contact_y": ("length", true, { $0.impactYcm }),
        "contact_distance": ("length", false, { $0.impactDistanceCm })
    ]

    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Reuse SessionDigest while withholding health data from the hosted model.
    static func digestObject(_ digest: SessionDigest) throws -> [String: Any] {
        var result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(digest)) as! [String: Any]
        result.removeValue(forKey: "averageHeartRate")
        result["measurement_note"] = "Motion metrics are estimates; mic-only shots have no speed, spin, angles or contact direction. Unavailable motion metrics are null."
        result["drill_target_options"] = Array(5...15)
        return result
    }

    func execute(name: String, arguments: String) -> String {
        do {
            guard let schema = Self.schemas.first(where: { ($0["function"] as? [String: Any])?["name"] as? String == name }),
                  let function = schema["function"] as? [String: Any],
                  let parameters = function["parameters"] as? [String: Any],
                  let properties = parameters["properties"] as? [String: [String: Any]],
                  let args = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]
            else { throw ToolError.invalid("Unknown tool or invalid argument object.") }
            guard Set(args.keys).isSubset(of: Set(properties.keys)) else { throw ToolError.invalid("Unknown argument.") }
            for key in parameters["required"] as? [String] ?? [] where args[key] == nil {
                throw ToolError.invalid("Missing argument: \(key)")
            }
            for (key, value) in args {
                let property = properties[key]!
                if property["type"] as? String == "string" {
                    guard let s = value as? String else { throw ToolError.invalid("\(key) must be a string.") }
                    if let allowed = property["enum"] as? [String], !allowed.contains(s) { throw ToolError.invalid("Invalid \(key).") }
                } else {
                    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else {
                        throw ToolError.invalid("\(key) must be a finite number.")
                    }
                }
            }
            return try Self.json(dispatch(name, args))
        } catch { return (try? Self.json(["error": error.localizedDescription])) ?? "{\"error\":\"Tool failed\"}" }
    }

    private func allSessions() throws -> [SessionRecord] {
        var records = try sessions().filter { $0.id != current.id }
        records.append(current)
        return records.sorted { $0.startDate < $1.startDate }
    }

    private func resolve(_ id: String?) throws -> SessionRecord {
        if id == nil || id == "current" { return current }
        let all = try allSessions()
        if id == "latest", let last = all.last { return last }
        if id == "previous", let previous = all.last(where: { $0.startDate < current.startDate }) { return previous }
        if let record = all.first(where: { $0.id.uuidString.lowercased() == id?.lowercased() }) { return record }
        throw ToolError.invalid("Session not found. Use an ID from get_session_digest.")
    }

    private func digest(_ session: SessionRecord) throws -> [String: Any] {
        var d = try Self.digestObject(SessionDigest(session: session, units: units))
        d["session_id"] = session.id.uuidString
        let shots = session.shots.filter { $0.type != .calibration }
        d["motion_shots"] = shots.filter(\.hasMotion).count
        var strokes = d["strokes"] as? [[String: Any]] ?? []
        for index in strokes.indices {
            let moving = shots.filter { $0.hasMotion && $0.type.label == strokes[index]["type"] as? String }
            if moving.isEmpty {
                for key in ["avgBallSpeed", "maxBallSpeed", "avgSwingSpeed", "avgSpinRPM", "avgPathDeg", "avgFaceDeg",
                            "avgContactTowardTip", "avgContactRight", "contactSpread"] { strokes[index][key] = NSNull() }
            } else {
                // Mic-only hits have no directional contact location; don't average their placeholder x/y.
                let summary = ShotSummary(moving)
                strokes[index]["avgContactTowardTip"] = units.length(summary.avgImpactY)
                strokes[index]["avgContactRight"] = units.length(summary.avgImpactX)
                strokes[index]["contactSpread"] = units.length(summary.impactSpreadCm)
            }
        }
        d["strokes"] = strokes
        let third = max(shots.count / 3, 1)
        if !shots.prefix(third).contains(where: \.hasMotion) { d["firstThirdAvgSpeed"] = NSNull() }
        if !shots.suffix(third).contains(where: \.hasMotion) { d["lastThirdAvgSpeed"] = NSNull() }
        return d
    }

    private func aggregate(_ shots: [ShotMetrics], metric: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["count": shots.count,
            "motion_count": shots.filter(\.hasMotion).count,
            "sweet_spot_percent": shots.isEmpty ? NSNull() : Double(shots.filter(\.isSweetSpot).count) / Double(shots.count) * 100]
        var values: [String: Any] = [:]
        for key in metric.map({ [$0] }) ?? Array(Self.metrics.keys) {
            guard let m = Self.metrics[key] else { continue }
            let samples = shots.filter { !m.motion || $0.hasMotion }.map(m.value).filter(\.isFinite)
            let converted = samples.map { m.unit == "speed" ? units.speed($0) : m.unit == "length" ? units.length($0) : $0 }
            values[key] = ["unit": m.unit == "speed" ? units.speedUnit : m.unit == "length" ? units.lengthUnit : m.unit,
                           "samples": converted.count, "mean": converted.isEmpty ? NSNull() : converted.reduce(0, +) / Double(converted.count),
                           "min": converted.min().map { $0 as Any } ?? NSNull(), "max": converted.max().map { $0 as Any } ?? NSNull()]
        }
        result["metrics"] = values
        return result
    }

    private func dispatch(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
        if name == "get_live_state" {
            guard let app else { throw ToolError.invalid("Live state unavailable.") }
            var result: [String: Any] = ["source": app.sourceKind.rawValue, "connected": app.isConnected,
                "connection": app.connectionLabel, "session_active": app.isSessionActive]
            if let shot = app.lastShot {
                result["last_shot"] = ["date": ISO8601DateFormatter().string(from: shot.date), "type": shot.type.rawValue,
                                       "statistics": aggregate([shot])]
            } else { result["last_shot"] = NSNull() }
            return result
        }
        if name == "compare_sessions" {
            let a = try resolve(args["a"] as? String), b = try resolve(args["b"] as? String)
            let sa = a.shots.filter { $0.type != .calibration }, sb = b.shots.filter { $0.type != .calibration }
            let ma = aggregate(sa)["metrics"] as! [String: [String: Any]], mb = aggregate(sb)["metrics"] as! [String: [String: Any]]
            var delta: [String: Any] = [:]
            for key in Self.metrics.keys {
                if let av = ma[key]?["mean"] as? Double, let bv = mb[key]?["mean"] as? Double {
                    delta[key] = ["value": bv - av, "unit": mb[key]!["unit"]!]
                }
            }
            return ["a": try digest(a), "b": try digest(b), "b_minus_a": delta]
        }
        if name == "get_session_digest" {
            return ["digest": try digest(resolve(args["session"] as? String)),
                    "sessions": try allSessions().map { ["id": $0.id.uuidString, "start": ISO8601DateFormatter().string(from: $0.startDate)] }]
        }
        let selected = args["session"] as? String == "all" ? try allSessions() : [try resolve(args["session"] as? String)]
        var shots = selected.flatMap(\.shots).filter { $0.type != .calibration }
        if let type = args["type"] as? String { shots = shots.filter { $0.type.rawValue == type } }
        if name == "query_shots" {
            func date(_ key: String) throws -> Date? {
                guard let raw = args[key] as? String else { return nil }
                let formatter = ISO8601DateFormatter()
                let basic = formatter.date(from: raw)
                formatter.formatOptions.insert(.withFractionalSeconds)
                guard let d = basic ?? formatter.date(from: raw) else { throw ToolError.invalid("\(key) must be an ISO 8601 timestamp.") }
                return d
            }
            let from = try date("from"), to = try date("to")
            if let from, let to, from > to { throw ToolError.invalid("from must precede to.") }
            shots = shots.filter { (from == nil || $0.date >= from!) && (to == nil || $0.date <= to!) }
            return aggregate(shots, metric: args["metric"] as? String)
        }
        // Simulate only shots with measured motion. Mic-only hits have no baseline swing.
        shots = shots.filter { $0.hasMotion && !$0.gyroSaturated && [$0.swingSpeedKmh, $0.faceAngleDeg, $0.swingPathDeg, $0.impactXcm, $0.impactYcm].allSatisfy(\.isFinite) }
        guard !shots.isEmpty else { throw ToolError.invalid("No usable motion shots to simulate; mic-only or saturated shots cannot supply a baseline.") }
        let s = ShotSummary(shots)
        let incoming = shots.reduce(0.0) { $0 + ($1.type == .serve ? 0 : $1.type == .volley ? 54 : 43.2) } / Double(shots.count)
        let base = ShotSimulator.Parameters(swingSpeedKmh: s.avgSwingKmh, pathAngleDeg: s.avgPathAngle,
            faceAngleDeg: s.avgFaceAngle, contactXcm: s.avgImpactX, contactYcm: s.avgImpactY, incomingSpeedKmh: incoming)
        func delta(_ key: String, _ limit: Double) -> Double { min(limit, max(-limit, args[key] as? Double ?? 0)) }
        let applied = ["swing_percent": delta("swing_percent", 30), "face_deg": delta("face_deg", 15),
                       "path_deg": delta("path_deg", 15), "contact_x_cm": delta("contact_x_cm", 5), "contact_y_cm": delta("contact_y_cm", 5)]
        var changed = base
        changed.swingSpeedKmh *= 1 + applied["swing_percent"]! / 100
        changed.faceAngleDeg += applied["face_deg"]!; changed.pathAngleDeg += applied["path_deg"]!
        changed.contactXcm += applied["contact_x_cm"]!; changed.contactYcm += applied["contact_y_cm"]!
        let model = app?.impactModel ?? ImpactModel()
        func output(_ p: ShotSimulator.Parameters) throws -> [String: Any] {
            let r = ShotSimulator.simulate(p, model: model)
            return ["ball_speed": units.speed(r.ballSpeedKmh), "speed_unit": units.speedUnit, "spin_rpm": r.spinRPM,
                    "spin_type": r.spin.rawValue, "applied_parameters": try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.parameters))]
        }
        return ["estimated": true, "sample_count": shots.count, "applied_deltas": applied,
                "before": try output(base), "after": try output(changed),
                "limitations": "Sensitivity estimate on an average shot, not a prediction. Incoming speed is assumed (serve 0, volley 54, groundstroke 43.2 km/h); incoming direction, side spin, contact height, launch angle and flight are unmodeled. Do not claim landing depth or net clearance."]
    }

    private enum ToolError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
    }
}
