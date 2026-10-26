import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Gemma 4 E2B (open weights, 4-bit MLX build) running fully on device.
/// First load downloads the weights from Hugging Face (mlx-community/gemma-4-e2b-it-4bit); after that it works offline.
final class GemmaCoach: CoachEngine, @unchecked Sendable {
    let name = "Gemma 4 E2B · on device"
    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    private func generate(_ prompt: String) async throws -> String {
        let session = ChatSession(container, instructions: CoachPrompts.system,
                                  generateParameters: GenerateParameters(maxTokens: 320, temperature: 0.4))
        let text = try await session.respond(to: prompt)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func summarize(_ digest: SessionDigest) async throws -> String { try await generate(CoachPrompts.summary(digest)) }
    func answer(_ q: String, digest: SessionDigest) async throws -> String { try await generate(CoachPrompts.question(q, digest)) }
    func drill(_ digest: SessionDigest) async throws -> String { try await generate(CoachPrompts.drill(digest)) }
}

enum GemmaLoader {
    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> CoachEngine {
        let container = try await #huggingFaceLoadModelContainer(
            configuration: LLMRegistry.gemma4_e2b_it_4bit,
            progressHandler: { p in progress(p.fractionCompleted) })
        return GemmaCoach(container: container)
    }
}
