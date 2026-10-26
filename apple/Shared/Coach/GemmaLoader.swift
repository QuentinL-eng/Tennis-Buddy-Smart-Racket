import Foundation

/// Loads Gemma 4 E2B on device. Replaced by the MLX implementation once the package is wired in.
enum GemmaLoader {
    struct NotAvailable: LocalizedError {
        var errorDescription: String? { "Gemma isn't bundled in this build yet." }
    }

    static func load(progress: @escaping @Sendable (Double) -> Void) async throws -> CoachEngine {
        throw NotAvailable()
    }
}
