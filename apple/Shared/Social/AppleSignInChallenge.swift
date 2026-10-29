import CryptoKit
import Foundation
import Security

/// Bind the returned Apple credential to one request. Only the hash goes to Apple;
/// Supabase receives the original nonce and verifies it against the signed identity token.
struct AppleSignInChallenge {
    let nonce: String
    let state: String

    init() throws {
        nonce = try Self.randomHex()
        state = try Self.randomHex()
    }

    var hashedNonce: String { Self.hash(nonce) }

    func validate(returnedState: String?) throws {
        guard returnedState == state else { throw AppleSignInError.invalidState }
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppleSignInError.randomUnavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum AppleSignInError: LocalizedError {
    case invalidState, missingToken, randomUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidState: "The Apple sign-in request expired. Please try again."
        case .missingToken: "Apple did not return a usable sign-in token. Please try again."
        case .randomUnavailable: "A secure sign-in request could not be created. Please try again."
        }
    }
}
