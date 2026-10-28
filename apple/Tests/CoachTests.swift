import XCTest
import RacketKit

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
        let model = CoachModel(keyProvider: { "test-key" }, clientFactory: { _ in fake })
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
        let model = CoachModel(keyProvider: { "test-key" }, clientFactory: { _ in fake })
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
        return MuseClient(apiKey: "test-key", session: URLSession(configuration: config))
    }
    func testTextAndToolResponseDecoding() async throws {
        let c = client(payload: #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Good contact."}}]}"#)
        let reply = try await c.complete(messages: [["role": "user", "content": "Hello"]], tools: CoachTools.schemas)
        XCTAssertEqual(reply["content"] as? String, "Good contact.")
        let request = MuseURLProtocol.capturedRequest!
        XCTAssertEqual(request.url, MuseClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
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
