import XCTest
import RacketKit
import simd

@MainActor
final class CoachToolsTests: XCTestCase {
    func shot(date: Date, speed: Double = 90, type: ShotType = .forehand) -> ShotMetrics {
        ShotMetrics(date: date, type: type, swingSpeedKmh: speed, ballSpeedKmh: speed * 1.4,
            spinRPM: 1600, spin: .topspin, faceAngleDeg: 0, swingPathDeg: 20,
            impactXcm: 1, impactYcm: 2, peakG: 100, gyroSaturated: false,
            features: ImpactFeatures(rollRatio: 0, ringNorm: 0, jolt: 0, impulse: 5))
    }
    func fixture() -> (SessionRecord, SessionRecord, CoachTools) {
        let a = SessionRecord(startDate: Date(timeIntervalSince1970: 1000))
        a.endDate = a.startDate.addingTimeInterval(60)
        a.averageHeartRate = 150
        a.shotRecords = [ShotRecord(metrics: shot(date: a.startDate, speed: 80))]
        let b = SessionRecord(startDate: Date(timeIntervalSince1970: 2000))
        b.endDate = b.startDate.addingTimeInterval(60)
        b.shotRecords = [ShotRecord(metrics: shot(date: b.startDate, speed: 100)),
                        ShotRecord(metrics: .fromMic(sweet: false, offCenterPercent: 80, date: b.startDate)),
                        ShotRecord(metrics: shot(date: b.startDate, type: .calibration))]
        return (a, b, CoachTools(current: b, app: nil, units: .init(metric: true), sessions: { [a, b] }))
    }
    func object(_ tools: CoachTools, _ name: String, _ args: String = "{}") throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(tools.execute(name: name, arguments: args).utf8)) as! [String: Any]
    }
    func testFilteringAndMissingMotion() throws {
        let (_, _, tools) = fixture()
        let query = try object(tools, "query_shots")
        XCTAssertEqual(query["count"] as? Int, 2)
        XCTAssertEqual(query["motion_count"] as? Int, 1)
        let metrics = query["metrics"] as! [String: [String: Any]]
        XCTAssertEqual(metrics["swing_speed"]?["mean"] as? Double, 100)
        let hit = try object(tools, "query_shots", "{\"type\":\"hit\",\"metric\":\"spin\"}")
        let hitMetrics = hit["metrics"] as! [String: [String: Any]]
        XCTAssertTrue(hitMetrics["spin"]?["mean"] is NSNull)
        let empty = try object(tools, "query_shots", "{\"from\":\"2026-01-01T00:00:00Z\"}")
        XCTAssertEqual(empty["count"] as? Int, 0)
        XCTAssertTrue(empty["sweet_spot_percent"] is NSNull)
    }
    func testComparisonCatalogAndHealthExclusion() throws {
        let (_, _, tools) = fixture()
        let result = try object(tools, "compare_sessions", "{\"a\":\"previous\",\"b\":\"current\"}")
        let delta = result["b_minus_a"] as! [String: [String: Any]]
        XCTAssertEqual(delta["swing_speed"]?["value"] as? Double, 20)
        let digest = try object(tools, "get_session_digest")
        XCTAssertEqual((digest["sessions"] as? [[String: Any]])?.count, 2)
        XCTAssertNil((result["a"] as? [String: Any])?["averageHeartRate"])
        let currentDigest = digest["digest"] as! [String: Any]
        let hit = (currentDigest["strokes"] as! [[String: Any]]).first { $0["type"] as? String == "Hit" }!
        XCTAssertTrue(hit["avgBallSpeed"] is NSNull)
        XCTAssertTrue(hit["avgContactTowardTip"] is NSNull)
    }
    func testValidationErrorsStayInToolResults() throws {
        let (_, _, tools) = fixture()
        for (name, args) in [("unknown", "{}"), ("query_shots", "[]"), ("query_shots", "{bad"),
            ("query_shots", "{\"type\":\"bogus\"}"), ("query_shots", "{\"from\":\"yesterday\"}"),
            ("compare_sessions", "{}"), ("query_shots", "{\"session\":\"bogus\"}"),
            ("simulate_change", "{\"face_deg\":true}"), ("get_live_state", "{}"),
            ("query_shots", "{\"from\":\"2026-01-02T00:00:00Z\",\"to\":\"2026-01-01T00:00:00Z\"}")] {
            XCTAssertNotNil(try object(tools, name, args)["error"], "\(name) \(args)")
        }
    }
    func testSimulationUsesPlayerBaselineAndClampsDeltas() throws {
        let (_, _, tools) = fixture()
        let result = try object(tools, "simulate_change", "{\"swing_percent\":999,\"face_deg\":100}")
        XCTAssertEqual(result["estimated"] as? Bool, true)
        XCTAssertEqual(result["sample_count"] as? Int, 1)
        let after = result["after"] as! [String: Any]
        let parameters = after["applied_parameters"] as! [String: Any]
        XCTAssertEqual(parameters["swingSpeedKmh"] as? Double, 130)
        XCTAssertEqual(parameters["faceAngleDeg"] as? Double, 15)
        XCTAssertNotNil(try object(tools, "simulate_change", "{\"type\":\"hit\"}")["error"])
    }
    func testListShotsFiltersOrdersAndLimits() throws {
        let (_, _, tools) = fixture()
        let newest = try object(tools, "list_shots", "{\"session\":\"all\",\"limit\":2}")
        XCTAssertEqual(newest["matching"] as? Int, 3)
        XCTAssertEqual(newest["returned"] as? Int, 2)
        let shots = newest["shots"] as! [[String: Any]]
        XCTAssertEqual(shots.first?["time"] as? String, "1970-01-01T00:33:20Z")
        let micOnly = shots.first { $0["has_motion"] as? Bool == false }!
        XCTAssertTrue(micOnly["ball_speed"] is NSNull)
        let oldest = try object(tools, "list_shots", "{\"session\":\"all\",\"order\":\"oldest\",\"type\":\"forehand\"}")
        XCTAssertEqual(((oldest["shots"] as! [[String: Any]]).first?["swing_speed"] as? Double), 80)
        let sweet = try object(tools, "list_shots", "{\"contact\":\"sweet_spot\"}")
        XCTAssertEqual(sweet["matching"] as? Int, 1)
        XCTAssertNotNil(try object(tools, "list_shots", "{\"order\":\"sideways\"}")["error"])
    }
    func testLiveSensorsAndStatusComeFromTheRacket() throws {
        let (_, b, _) = fixture()
        let now = Date()
        let flat = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
        let live = (0..<30).map { i in
            (date: now.addingTimeInterval(Double(i - 30) / 30), state: LiveState(orientation: flat, gyroDps: Float(i * 20), highG: 1, samplesPerSecond: 980))
        }
        let status = RacketProtocol.Status(batteryMillivolts: 3900, firmwareVersion: "1.6.0", mpuOK: true, h3lisOK: true,
                                           streaming: true, h3lisRange: 3, droppedPackets: 2, impactMode: true, gyro4000: true)
        let tools = CoachTools(current: b, app: nil, units: .init(metric: true),
            readout: { RacketReadout(source: "racket", connected: true, connection: "Connected", status: status, live: live) },
            sessions: { [b] })
        let sensors = try object(tools, "read_live_sensors", "{\"seconds\":2}")
        XCTAssertEqual(sensors["readings"] as? Int, 30)
        XCTAssertEqual((sensors["gyro_dps"] as? [String: Any])?["max"] as? Double, 580)
        XCTAssertEqual(sensors["swinging"] as? Bool, true)
        XCTAssertEqual(sensors["tip_elevation_deg"] as? Double, 0)
        XCTAssertEqual(sensors["face_tilt_deg"] as? Double, 90)
        let hardware = try object(tools, "get_racket_status")["hardware"] as! [String: Any]
        XCTAssertEqual(hardware["gyro_range_dps"] as? Int, 4000)
        XCTAssertEqual(hardware["high_g_range_g"] as? Int, 399)
        XCTAssertEqual(hardware["battery_mv"] as? Int, 3900)
        let offline = CoachTools(current: b, app: nil,
            readout: { RacketReadout(source: "racket", connected: false, connection: "Searching") }, sessions: { [b] })
        XCTAssertNotNil(try object(offline, "read_live_sensors")["error"])
        XCTAssertTrue(try object(offline, "get_racket_status")["hardware"] is NSNull)
    }
    func testNotesRecallSaveAndLimits() throws {
        let (_, b, _) = fixture()
        let player = UUID()
        let old = CoachNote(playerID: player, text: "Sore right elbow last spring", category: .injury)
        old.updatedAt = Date(timeIntervalSince1970: 0)
        let memory = CoachMemory.inMemory([old, CoachNote(playerID: player, text: "Wants a heavier kick serve", category: .goal)],
                                          playerID: player)
        let tools = CoachTools(current: b, app: nil, memory: memory, sessions: { [b] })
        XCTAssertEqual(try object(tools, "recall_notes")["matching"] as? Int, 2)
        let injury = try object(tools, "recall_notes", "{\"category\":\"injury\"}")["notes"] as! [[String: Any]]
        XCTAssertEqual(injury.first?["text"] as? String, "Sore right elbow last spring")
        XCTAssertEqual(try object(tools, "recall_notes", "{\"query\":\"elbow pain\"}")["matching"] as? Int, 1)
        XCTAssertEqual(try object(tools, "remember_note", "{\"text\":\"wants a heavier kick serve\",\"category\":\"goal\"}")["saved"] as? Bool, false)
        XCTAssertNotNil(try object(tools, "remember_note", "{\"text\":\"ok\",\"category\":\"goal\"}")["error"])
        XCTAssertNotNil(try object(tools, "remember_note", "{\"text\":\"Rushes backhand\",\"category\":\"mood\"}")["error"])
        XCTAssertEqual(try object(tools, "remember_note", "{\"text\":\"Rushes the backhand when tired\",\"category\":\"technique\"}")["saved"] as? Bool, true)
        XCTAssertEqual(try object(tools, "remember_note", "{\"text\":\"Prefers morning sessions\",\"category\":\"preference\"}")["saved"] as? Bool, true)
        XCTAssertNotNil(try object(tools, "remember_note", "{\"text\":\"A third note\",\"category\":\"other\"}")["error"])
        XCTAssertEqual(try memory.notes().filter(\.addedByCoach).count, 2)
        let off = CoachTools(current: b, app: nil, sessions: { [b] })
        XCTAssertNotNil(try object(off, "recall_notes")["error"])
        XCTAssertNotNil(try object(off, "remember_note", "{\"text\":\"Anything at all\",\"category\":\"other\"}")["error"])
    }
    func testWhatIfScreenMatchesTheTool() throws {
        let (_, b, tools) = fixture()
        let result = try object(tools, "simulate_change", "{\"swing_percent\":-5,\"face_deg\":3}")
        let after = (result["after"] as! [String: Any])["applied_parameters"] as! [String: Any]
        let base = WhatIf.baseline(b.shots)!
        let p = WhatIf.apply(.init(swingPercent: -5, faceDeg: 3), to: base.parameters)
        XCTAssertEqual(after["swingSpeedKmh"] as! Double, p.swingSpeedKmh, accuracy: 1e-9)
        XCTAssertEqual(after["faceAngleDeg"] as! Double, p.faceAngleDeg, accuracy: 1e-9)
        XCTAssertEqual(result["sample_count"] as? Int, base.sampleCount)
        XCTAssertEqual(WhatIf.describe(.init(swingPercent: -5, faceDeg: 3), units: .init(metric: true)),
                       "open the face 3° and swing 5% slower")
        XCTAssertNil(WhatIf.baseline([ShotMetrics.fromMic(sweet: true, offCenterPercent: 0)]))
    }
    func testImperialConversion() throws {
        let (a, b, _) = fixture()
        let tools = CoachTools(current: b, app: nil, units: .init(metric: false), sessions: { [a, b] })
        let result = try object(tools, "query_shots", "{\"metric\":\"swing_speed\"}")
        let metrics = result["metrics"] as! [String: [String: Any]]
        XCTAssertEqual(metrics["swing_speed"]?["mean"] as! Double, 100 / 1.609344, accuracy: 0.001)
        XCTAssertEqual(metrics["swing_speed"]?["unit"] as? String, "mph")
    }
}

@MainActor
final class MuseLoopTests: XCTestCase {
    final class Fake: MuseTransport {
        var requests: [([[String: Any]], [[String: Any]])] = []
        var reply: [String: Any] = ["role": "assistant", "content": "A coaching answer."]
        var toolRounds = 0
        var fail = false
        func complete(messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
            requests.append((messages, tools))
            if fail { throw MuseError.http(429) }
            if toolRounds > 0 {
                toolRounds -= 1
                return ["role": "assistant", "content": NSNull(), "reasoning_content": "opaque test context", "tool_calls": [
                    ["id": "query", "type": "function", "function": ["name": "query_shots", "arguments": "{}"]],
                    ["id": "bad", "type": "function", "function": ["name": "unknown", "arguments": "{}"]]]]
            }
            return reply
        }
    }
    func testToolRoundReplaysAssistantAndEveryResult() async throws {
        let fake = Fake(); fake.toolRounds = 1
        let s = SessionRecord()
        let tools = CoachTools(current: s, app: nil, sessions: { [s] })
        let coach = MuseCoach(client: fake, tools: tools)
        let text = try await coach.answer("How was my shot?", digest: SessionDigest(session: s))
        XCTAssertEqual(text, "A coaching answer.")
        XCTAssertEqual(fake.requests.count, 2)
        let history = fake.requests[1].0
        XCTAssertTrue(history.contains { $0["reasoning_content"] as? String == "opaque test context" })
        let results = history.filter { ["query", "bad"].contains($0["tool_call_id"] as? String ?? "") }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { ($0["content"] as? String)?.contains("error") == true })
        XCTAssertFalse(try CoachTools.json(history).contains("averageHeartRate"))
    }
    func testQuestionsLetTheAgentFetchItsOwnData() async throws {
        let fake = Fake()
        let s = SessionRecord()
        let coach = MuseCoach(client: fake, tools: CoachTools(current: s, app: nil, sessions: { [s] }))
        _ = try await coach.answer("How was my backhand?", digest: SessionDigest(session: s))
        let first = fake.requests[0]
        XCTAssertEqual(first.0.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertTrue((first.0[1]["content"] as? String)?.contains("How was my backhand?") == true)
        let names = first.1.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        for tool in ["list_shots", "read_live_sensors", "get_racket_status", "recall_notes", "remember_note"] {
            XCTAssertTrue(names.contains(tool), tool)
        }
        _ = try await coach.summarize(SessionDigest(session: s))
        XCTAssertEqual(fake.requests[1].0.count, 4)   // summaries still start from the digest
    }
    func testRoundLimitStopsEvenIfModelKeepsCallingTools() async {
        let fake = Fake(); fake.toolRounds = 100
        let s = SessionRecord()
        let coach = MuseCoach(client: fake, tools: CoachTools(current: s, app: nil, sessions: { [s] }))
        do { _ = try await coach.drill(SessionDigest(session: s)); XCTFail("Expected limit") }
        catch { XCTAssertTrue(error is MuseError) }
        XCTAssertEqual(fake.requests.count, 5)
        XCTAssertTrue(fake.requests.last!.1.isEmpty)
    }
    func testEmptyAnswerAndTransportFailurePropagate() async {
        let fake = Fake(); fake.reply = ["role": "assistant", "content": " "]
        let s = SessionRecord()
        let coach = MuseCoach(client: fake, tools: CoachTools(current: s, app: nil, sessions: { [s] }))
        do { _ = try await coach.summarize(SessionDigest(session: s)); XCTFail() } catch {}
        fake.fail = true
        do { _ = try await coach.summarize(SessionDigest(session: s)); XCTFail() } catch {}
    }
}

@MainActor
final class CoachFallbackTests: XCTestCase {
    func testMuseFailureFallsBackAndReportsActualEngine() async {
        let original = UserDefaults.standard.object(forKey: "coach.museEnabled")
        defer { UserDefaults.standard.set(original, forKey: "coach.museEnabled") }
        let fake = MuseLoopTests.Fake(); fake.fail = true
        let model = CoachModel(transportProvider: { fake })
        model.setSignedIn(true)
        model.museEnabled = true
        let text = await model.summarize(SessionRecord())
        XCTAssertEqual(text, "No shots recorded yet. Start a session and hit a few balls.")
        XCTAssertEqual(model.engineName, "Built-in coach")
        XCTAssertNotNil(model.lastFallbackReason)
        XCTAssertFalse(model.isWorking)
    }
    func testMuseSuccessAndDisabledMode() async {
        let original = UserDefaults.standard.object(forKey: "coach.museEnabled")
        defer { UserDefaults.standard.set(original, forKey: "coach.museEnabled") }
        let fake = MuseLoopTests.Fake()
        let model = CoachModel(transportProvider: { fake })
        model.setSignedIn(true)
        model.museEnabled = true
        let text = await model.summarize(SessionRecord())
        XCTAssertEqual(text, "A coaching answer.")
        XCTAssertEqual(model.engineName, "Muse Spark · online")
        model.museEnabled = false
        _ = await model.summarize(SessionRecord())
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(model.engineName, "Built-in coach")
    }
}

final class MuseURLProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var payload = Data()
    static var capturedRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.capturedRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class MuseClientTests: XCTestCase {
    func client(status: Int = 200, payload: String) -> MuseClient {
        MuseURLProtocol.status = status
        MuseURLProtocol.payload = Data(payload.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MuseURLProtocol.self]
        return MuseClient(endpoint: URL(string: "https://example.supabase.co/functions/v1/muse")!, publishableKey: "pub", accessToken: "user-jwt", session: URLSession(configuration: config))
    }
    func testTextAndToolResponseDecoding() async throws {
        let c = client(payload: #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Good contact."}}]}"#)
        let reply = try await c.complete(messages: [["role": "user", "content": "Hello"]], tools: CoachTools.schemas)
        XCTAssertEqual(reply["content"] as? String, "Good contact.")
        let request = MuseURLProtocol.capturedRequest!
        XCTAssertEqual(request.url, c.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-jwt")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "pub")
        let toolClient = client(payload: #"{"choices":[{"finish_reason":"tool_calls","message":{"role":"assistant","content":null,"tool_calls":[{"id":"1","type":"function","function":{"name":"get_live_state","arguments":"{}"}}]}}]}"#)
        let toolReply = try await toolClient.complete(messages: [], tools: CoachTools.schemas)
        XCTAssertEqual((toolReply["tool_calls"] as? [[String: Any]])?.count, 1)
    }
    func testRateLimitAndTruncatedResponsesThrow() async {
        let rate = client(status: 429, payload: "{}")
        do { _ = try await rate.complete(messages: [], tools: []); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "Muse request failed (HTTP 429).") }
        let truncated = client(payload: #"{"choices":[{"finish_reason":"length","message":{"role":"assistant","content":"Partial"}}]}"#)
        do { _ = try await truncated.complete(messages: [], tools: []); XCTFail() } catch {}
    }
}
