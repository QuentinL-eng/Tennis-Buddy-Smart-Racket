import AuthenticationServices
import Foundation
import Observation
import Supabase
import SwiftData
import RacketKit

@MainActor
@Observable
final class AccountModel {
    private(set) var userID: UUID?
    private(set) var dashboard: SocialDashboard?
    private(set) var sharedMatch: SharedMatchState? {
        didSet { onSharedMatchChange?(sharedMatch, userID) }
    }
    @ObservationIgnored var onSharedMatchChange: ((SharedMatchState?, UUID?) -> Void)?
    var isBusy = false
    var errorMessage: String?
    private(set) var lastSync: Date?
    @ObservationIgnored let client: SupabaseClient?
    @ObservationIgnored private var museConfig: (url: URL, key: String)?
    private var refreshInProgress = false
    private var statsSyncInProgress = false
    private var generation = 0
    @ObservationIgnored private var appleChallenge: AppleSignInChallenge?

    init() {
        if let url = Bundle.main.url(forResource: "BackendConfig", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let config = try? PropertyListDecoder().decode(Configuration.self, from: data),
           let endpoint = URL(string: config.url), endpoint.scheme == "https", endpoint.host != nil,
           !config.publishableKey.isEmpty, !config.publishableKey.hasPrefix("sb_secret_") {
            client = SupabaseClient(supabaseURL: endpoint, supabaseKey: config.publishableKey)
            museConfig = (endpoint.appendingPathComponent("functions/v1/muse"), config.publishableKey)
        } else { client = nil }
    }

    private struct Configuration: Decodable { let url: String; let publishableKey: String }
    var isConfigured: Bool { client != nil }
    var isSignedIn: Bool { userID != nil }

    /// Transport for the online coach, authenticated as the signed-in user. nil when signed out.
    func museTransport() async -> MuseTransport? {
        guard let client, let museConfig, isSignedIn,
              let token = try? await client.auth.session.accessToken else { return nil }
        return MuseClient(endpoint: museConfig.url, publishableKey: museConfig.key, accessToken: token)
    }
    var displayName: String? { dashboard?.profile.name }

    func observeAuthentication() async {
        guard let client else { return }
        for await (_, session) in client.auth.authStateChanges {
            if Task.isCancelled { return }
            let id = session?.user.id
            if id != userID {
                generation += 1
                dashboard = nil; sharedMatch = nil; lastSync = nil
                userID = id
            }
            if id != nil { await refresh() }
        }
    }

    func signInWithGoogle() async {
        await perform {
            guard let client = self.client else { return }
            _ = try await client.auth.signInWithOAuth(provider: .google,
                redirectTo: URL(string: "tennisbuddee://auth/callback")!)
        }
    }

    func prepareAppleSignIn(_ request: ASAuthorizationAppleIDRequest) {
        appleChallenge = nil
        errorMessage = nil
        do {
            let challenge = try AppleSignInChallenge()
            appleChallenge = challenge
            request.requestedScopes = [.email, .fullName]
            request.nonce = challenge.hashedNonce
            request.state = challenge.state
        } catch { errorMessage = error.localizedDescription }
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        let challenge = appleChallenge
        appleChallenge = nil // Never reuse a completed or cancelled challenge.
        if case .failure(let error) = result,
           (error as? ASAuthorizationError)?.code == .canceled {
            errorMessage = nil
            return
        }
        await perform {
            guard let client = self.client else { throw SocialError.signInRequired }
            let authorization = try result.get()
            guard let challenge else { throw AppleSignInError.invalidState }
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                throw AppleSignInError.missingToken
            }
            try challenge.validate(returnedState: credential.state)
            _ = try await client.auth.signInWithIdToken(credentials: .init(
                provider: .apple, idToken: token, nonce: challenge.nonce))
            // Apple gives the name only on the first consent. Preserve a later custom name.
            if let name = credential.fullName?.formatted().trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                do {
                    _ = try await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
                    let dashboard: SocialDashboard = try await client.rpc("social_dashboard").execute().value
                    if dashboard.profile.name == "Tennis player" {
                        let _: Bool = try await client.rpc("set_player_name",
                            params: ["p_name": String(name.prefix(60))]).execute().value
                    }
                } catch {
                    self.errorMessage = "Signed in with Apple. You can set your player name in Account."
                }
            }
            await self.refresh()
        }
    }

    func signOut() async {
        await perform {
            try await self.client?.auth.signOut(scope: .local)
            self.generation += 1
            self.userID = nil; self.dashboard = nil; self.sharedMatch = nil; self.lastSync = nil
        }
    }

    func refresh() async {
        guard isSignedIn, !refreshInProgress else { return }
        refreshInProgress = true
        let expected = generation
        defer { refreshInProgress = false }
        do {
            let result: SocialDashboard = try await rpc("social_dashboard")
            guard expected == generation else { return }
            dashboard = result
            if let id = sharedMatch?.id {
                let state: SharedMatchState = try await rpc("shared_match_state", ["p_match": .string(id.uuidString)])
                guard expected == generation, sharedMatch?.id == id else { return }
                sharedMatch = state
            }
            lastSync = Date()
        } catch { if expected == generation { errorMessage = error.localizedDescription } }
    }

    func saveName(_ raw: String) async {
        let name = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty else { return }
        await action("set_player_name", ["p_name": .string(name)])
    }

    func requestFriend(code: String) async {
        await action("request_friend", ["p_code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())])
    }
    func respond(to id: UUID, accept: Bool) async {
        await action("respond_friend", ["p_player": .string(id.uuidString), "p_accept": .bool(accept)])
    }
    func removeFriend(_ id: UUID) async {
        await action("remove_friend", ["p_player": .string(id.uuidString)])
    }

    func createMatch(title: String, friend: UUID? = nil) async {
        await perform {
            let state: SharedMatchState = try await self.rpc("create_shared_match", [
                "p_title": .string(title.trimmingCharacters(in: .whitespacesAndNewlines)),
                "p_friend": friend.map { .string($0.uuidString) } ?? .null])
            self.sharedMatch = state
            await self.refresh()
        }
    }
    func join(code: String) async {
        await perform {
            self.sharedMatch = try await self.rpc("join_shared_match", [
                "p_code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())])
            await self.refresh()
        }
    }
    func acceptInvitation(_ id: UUID) async {
        await perform {
            self.sharedMatch = try await self.rpc("accept_match_invitation", ["p_match": .string(id.uuidString)])
            await self.refresh()
        }
    }
    func declineInvitation(_ id: UUID) async {
        await action("decline_match_invitation", ["p_match": .string(id.uuidString)])
    }
    func openMatch(_ id: UUID) async {
        await perform { self.sharedMatch = try await self.rpc("shared_match_state", ["p_match": .string(id.uuidString)]) }
    }
    func closeMatch() { sharedMatch = nil }

    func award(won: Bool, operation: UUID = UUID()) async {
        guard let state = sharedMatch, let me = userID, let guest = state.guest,
              !state.ended, state.tracker(for: me).score.winner == nil else { return }
        let other = state.host.id == me ? guest.id : state.host.id
        await action("add_shared_point", ["p_match": .string(state.id.uuidString),
            "p_winner": .string((won ? me : other).uuidString), "p_operation": .string(operation.uuidString),
            "p_expected_revision": .integer(state.revision)])
    }
    func undo() async {
        guard let state = sharedMatch, let last = state.points.last else { return }
        await action("undo_shared_point", ["p_match": .string(state.id.uuidString), "p_point": .string(last.id.uuidString)])
    }
    func endMatch() async {
        guard let state = sharedMatch else { return }
        await action("end_shared_match", ["p_match": .string(state.id.uuidString)])
    }

    /// Upload only the local player's racket summary, never Health data or private session notes.
    func shareStats(_ stats: SharedPlayerStats, matchID: UUID) async throws {
        let _: Bool = try await rpc("share_racket_stats", ["p_match": .string(matchID.uuidString),
            "p_shots": .integer(stats.shots), "p_sweet": .double(stats.sweetPercent),
            "p_average": stats.averageBallKmh.map(AnyJSON.double) ?? .null,
            "p_top": stats.topBallKmh.map(AnyJSON.double) ?? .null])
    }

    func syncPendingStats(in context: ModelContext) async {
        guard let me = userID else { return }
        guard !statsSyncInProgress else { return }
        statsSyncInProgress = true
        defer { statsSyncInProgress = false }
        let records = (try? context.fetch(FetchDescriptor<SessionRecord>())) ?? []
        let mine = records.filter { $0.sharedPlayerID == me.uuidString }
        let pendingIDs = Set(mine.filter(\.sharedStatsPending).map(\.sharedMatchID))
        for id in pendingIDs {
            guard let matchID = UUID(uuidString: id), userID == me else { continue }
            let sessions = mine.filter { $0.sharedMatchID == id }
            let counts = sessions.map { $0.shotRecords?.count ?? 0 }
            let shots = sessions.flatMap { $0.shotRecords ?? [] }.filter { $0.dataSourceRaw == "racket" }
                .compactMap(\.metrics).filter { $0.type != .calibration }
            let all = ShotSummary(shots)
            let motion = ShotSummary(shots.filter { $0.type != .hit && !$0.gyroSaturated })
            do {
                try await shareStats(SharedPlayerStats(id: me, shots: all.count, sweetPercent: all.sweetSpotPercent,
                    averageBallKmh: motion.count > 0 ? motion.avgBallKmh : nil,
                    topBallKmh: motion.count > 0 ? motion.maxBallKmh : nil), matchID: matchID)
                for (index, session) in sessions.enumerated() where userID == me && counts[index] == session.shotRecords?.count {
                    session.sharedStatsPending = false
                }
                try context.save()
            } catch {
                // Keep the durable pending flag so a later foreground sync retries this summary.
                errorMessage = "Racket stats are waiting to sync. " + error.localizedDescription
                return
            }
        }
    }

    private func rpc<T: Decodable>(_ function: String, _ params: [String: AnyJSON] = [:]) async throws -> T {
        guard let client, isSignedIn else { throw SocialError.signInRequired }
        return try await client.rpc(function, params: params).execute().value
    }
    private func action(_ function: String, _ params: [String: AnyJSON]) async {
        await perform {
            let _: Bool = try await self.rpc(function, params)
            await self.refresh()
        }
    }
    private func perform(_ body: () async throws -> Void) async {
        guard !isBusy else { errorMessage = "A change is already syncing. Please try again."; return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do { try await body() } catch { errorMessage = error.localizedDescription }
    }
}

private enum SocialError: LocalizedError {
    case signInRequired
    var errorDescription: String? { "Sign in to use friends and shared sessions." }
}
