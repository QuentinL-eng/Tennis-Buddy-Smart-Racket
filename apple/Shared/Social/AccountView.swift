import AuthenticationServices
import SwiftUI

struct AccountView: View {
    @Environment(AccountModel.self) private var account
    @State private var name = ""
    @State private var signingOut = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            if account.isSignedIn {
                Section("Profile") {
                    TextField("Your name", text: $name)
                        .onSubmit { saveName() }
                        .submitLabel(.done)
                    if let profile = account.dashboard?.profile {
                        LabeledContent("Friend code", value: profile.friendCode).textSelection(.enabled)
                        ShareLink("Share friend code", item: "Add me on Tennis Buddee: \(profile.friendCode)")
                    }
                }
                Section {
                    NavigationLink { SharedSessionView() } label: { Label("Friends & shared sessions", systemImage: "person.2") }
                    Button("Sign out", role: .destructive) { signingOut = true }
                } footer: {
                    Text("Your private session history stays on this device and in your iCloud account. Only shared match scores and racket summaries are visible to your opponent.")
                }
            } else {
                Section {
                    Text("Play together").font(.title2.bold())
                    Text("Sign in to save your player profile, add friends, and share match scores.")
                    SignInWithAppleButton(.signIn) { request in
                        account.prepareAppleSignIn(request)
                    } onCompletion: { result in
                        Task { await account.completeAppleSignIn(result) }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 44)
                    .frame(maxWidth: 360)
                    Button("Sign in with Google") { Task { await account.signInWithGoogle() } }
                        .buttonStyle(.bordered)
                }
                .disabled(!account.isConfigured)
                if !account.isConfigured {
                    Section { Text("Online accounts are not available in this build yet. You can still record sessions and customise your racket.") }
                }
            }
            if account.isBusy { ProgressView() }
            if let error = account.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .formStyle(.grouped)
        .navigationTitle("Account")
        .disabled(account.isBusy)
        .task { await account.refresh(); name = account.displayName ?? "" }
        .task(id: name) {
            // Debounced autosave: wait for a pause in typing, skip unchanged or empty names.
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != account.displayName else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveName()
        }
        .onChange(of: account.displayName) { _, value in name = value ?? "" }
        .confirmationDialog("Sign out of Tennis Buddee?", isPresented: $signingOut) {
            Button("Sign out", role: .destructive) { Task { await account.signOut() } }
        }
    }

    private func saveName() {
        let value = name
        Task { await account.saveName(value) }
    }
}
