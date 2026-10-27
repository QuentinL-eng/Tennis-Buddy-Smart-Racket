import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Meta Llama 3.2 3B Instruct (open weights, 4-bit MLX build, ~1.8 GB) running fully on device.
/// Sized for iPhone 15 and up (6 GB RAM, with the increased-memory-limit entitlement).
/// First load downloads the weights from Hugging Face (mlx-community/Llama-3.2-3B-Instruct-4bit); after that it works offline.
final class LlamaCoach: CoachEngine, @unchecked Sendable {
    let name = "Llama 3.2 3B · on device"
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

enum LlamaLoader {
    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> CoachEngine {
        let container = try await #huggingFaceLoadModelContainer(
            configuration: LLMRegistry.llama3_2_3B_4bit,
            progressHandler: { p in progress(p.fractionCompleted) })
        return LlamaCoach(container: container)
    }
}
