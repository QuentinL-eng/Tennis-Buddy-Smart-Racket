import RacketKit
import SwiftUI

struct SharedSessionView: View {
    @Environment(AccountModel.self) private var account
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var friendCode = ""
    @State private var matchCode = ""
    @State private var title = ""
    @State private var confirmEnd = false

    var body: some View {
        Form {
            if !account.isSignedIn {
                Section {
                    Text("Sign in to invite friends and share a session.")
                    NavigationLink("Sign in") { AccountView() }
                }
            } else if let state = account.sharedMatch, let me = account.userID {
                matchSection(state, me: me)
            } else {
                lobby
            }
            if account.isBusy { ProgressView() }
            if let error = account.errorMessage {
                Section {
                    Text(error).font(.callout).foregroundStyle(.red)
                    Button("Refresh") { Task { await account.refresh() } }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Play together")
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await account.refresh()
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .confirmationDialog("End this shared match for both players?", isPresented: $confirmEnd) {
            Button("End shared match", role: .destructive) { Task { await account.endMatch() } }
        }
    }

    @ViewBuilder private var lobby: some View {
        if let dashboard = account.dashboard {
            if !dashboard.invitations.isEmpty {
                Section("Session invitations") {
                    ForEach(dashboard.invitations) { invite in
                        VStack(alignment: .leading) {
                            Text(invite.title).font(.headline)
                            Text("From \(invite.hostName)").foregroundStyle(.secondary)
                            HStack {
                                Button("Join") { Task { await account.acceptInvitation(invite.id) } }
                                Button("Decline", role: .destructive) { Task { await account.declineInvitation(invite.id) } }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            if !dashboard.matches.isEmpty {
                Section("Your shared matches") {
                    ForEach(dashboard.matches) { match in
                        Button(match.title) { Task { await account.openMatch(match.id) } }
                    }
                }
            }
            Section {
                TextField("Session name (optional)", text: $title)
                if dashboard.friends.isEmpty {
                    Text("Add a friend below to invite them directly.").foregroundStyle(.secondary)
                }
                ForEach(dashboard.friends) { friend in
                    HStack {
                        Text(friend.name)
                        Spacer()
                        Button("Invite") { Task { await account.createMatch(title: title, friend: friend.id) } }
                            .buttonStyle(.bordered)
                        Menu {
                            Button("Remove friend", role: .destructive) { Task { await account.removeFriend(friend.id) } }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
                Button("Create session with a code") { Task { await account.createMatch(title: title) } }
            } header: { Text("Invite a friend") } footer: {
                Text("Friends receive an invitation in the app. A smart racket is optional for either player.")
            }
            if !dashboard.requests.isEmpty {
                Section("Friend requests") {
                    ForEach(dashboard.requests) { request in
                        HStack {
                            Text(request.player.name)
                            Spacer()
                            if request.incoming {
                                Button("Accept") { Task { await account.respond(to: request.id, accept: true) } }
                                    .buttonStyle(.bordered)
                                Button("Decline", role: .destructive) { Task { await account.respond(to: request.id, accept: false) } }
                                    .buttonStyle(.bordered)
                            } else { Text("Pending").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section {
                LabeledContent("Your friend code", value: dashboard.profile.friendCode).textSelection(.enabled)
                ShareLink("Share friend code", item: "Add me on Tennis Buddee: \(dashboard.profile.friendCode)")
                TextField("Their friend code", text: $friendCode).autocorrectionDisabled()
                Button("Send friend request") { Task { await account.requestFriend(code: friendCode) } }
                    .disabled(friendCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("Add a friend once") } footer: {
                Text("Once they accept, you can invite each other without entering a code again.")
            }
        }
        Section("Join with a session code") {
            TextField("Session code", text: $matchCode).autocorrectionDisabled()
            Button("Join session") { Task { await account.join(code: matchCode) } }
                .disabled(matchCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .disabled(account.isBusy)
    }

    @ViewBuilder private func matchSection(_ state: SharedMatchState, me: UUID) -> some View {
        let tracker = state.tracker(for: me)
        let opponent = state.host.id == me ? state.guest?.name : state.host.name
        Section(state.title) {
            LabeledContent("You", value: account.displayName ?? "You")
            LabeledContent("Opponent", value: opponent ?? "Waiting for a player")
            HStack {
                Text(tracker.score.pointText).font(.largeTitle.bold().monospacedDigit())
                Spacer()
                Text(tracker.setsText).font(.title3.monospacedDigit())
            }
            Text("Best of 3 sets · advantage scoring").font(.caption).foregroundStyle(.secondary)
            if state.ended {
                Text("Match ended").font(.headline)
            } else if state.guest == nil {
                LabeledContent("Session code", value: state.inviteCode).textSelection(.enabled)
                ShareLink("Share session code", item: "Join my Tennis Buddee session: \(state.inviteCode)")
                Text("Friend invitations also appear in your friend's Play together screen.").font(.caption)
            } else {
                HStack {
                    Button("I won") { Task { await account.award(won: true) } }
                    Button("They won") { Task { await account.award(won: false) } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(account.isBusy || tracker.score.winner != nil)
                Button("Undo last point", systemImage: "arrow.uturn.backward") { Task { await account.undo() } }
                    .disabled(account.isBusy || state.points.isEmpty)
                if let winner = tracker.score.winner {
                    Text(winner == .me ? "You won the match" : "Your opponent won the match").font(.headline)
                }
            }
            if let sync = account.lastSync {
                Text("Updated \(sync.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
        }
        Section {
            if app.activeSession?.sharedMatchID == state.id.uuidString {
                Text("Your racket stats are being shared from this session.")
            } else if !state.ended {
                Button("Record my racket stats") { app.startSharedRecording(matchID: state.id, playerID: me) }
                    .disabled(app.isSessionActive || app.sourceKind != .racket)
                Text(app.isSessionActive ? "End your current recording first." : app.sourceKind != .racket
                     ? "Select and connect your smart racket in the Racket tab to share shots."
                     : "Start a recording to share your shots. Scoring works without a racket.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach([state.host] + (state.guest.map { [$0] } ?? [])) { player in
                VStack(alignment: .leading, spacing: 4) {
                    Text(player.id == me ? "Your racket" : "\(player.name)'s racket").font(.headline)
                    if let stats = state.stats.first(where: { $0.id == player.id }) {
                        Text("\(stats.shots) shots · \(Int(stats.sweetPercent))% sweet spot")
                        if let average = stats.averageBallKmh {
                            Text("Average ball \(UnitSystem.current.speedText(average))")
                        }
                    } else { Text("No racket stats shared").foregroundStyle(.secondary) }
                }
            }
        } header: { Text("Shared stats") } footer: {
            Text("Only real racket shots are shared. Heart rate, calories, and private session notes stay private.")
        }
        Section {
            Button("Back to friends") { account.closeMatch() }
            if !state.ended { Button("End shared match", role: .destructive) { confirmEnd = true } }
        }
    }
}
