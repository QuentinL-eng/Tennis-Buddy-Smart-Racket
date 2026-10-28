import Foundation

/// JSON objects preserve the full assistant message, including provider reasoning fields, on replay.
@MainActor
protocol MuseTransport {
    func complete(messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any]
}

enum MuseError: LocalizedError {
    case invalidResponse, http(Int), roundLimit, noKey
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Muse returned an incomplete response."
        case .http(let code): "Muse request failed (HTTP \(code))."
        case .roundLimit: "Muse reached the coaching tool limit."
        case .noKey: "Add your Meta Model API key to enable Muse."
        }
    }
}

@MainActor
struct MuseClient: MuseTransport {
    static let endpoint = URL(string: "https://api.meta.ai/v1/chat/completions")!
    let apiKey: String
    var model = "muse-spark-1.3"
    var session: URLSession = .shared

    func complete(messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw MuseError.noKey }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages,
                                   "max_completion_tokens": 2048, "reasoning_effort": "low"]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // No automatic retries: rate limits and network errors immediately use the local fallback.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MuseError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw MuseError.http(http.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]], let choice = choices.first,
              let reason = choice["finish_reason"] as? String, ["stop", "tool_calls"].contains(reason),
              let message = choice["message"] as? [String: Any], message["role"] as? String == "assistant"
        else { throw MuseError.invalidResponse }
        return message
    }
}
