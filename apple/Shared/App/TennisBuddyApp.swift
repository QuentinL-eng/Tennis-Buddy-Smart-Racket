import RacketKit
import SwiftData
import SwiftUI

@main
struct TennisBuddyApp: App {
    @State private var model = AppModel()
    @State private var coach = CoachModel()
    @State private var account = AccountModel()
    @Environment(\.scenePhase) private var scenePhase
    let container: ModelContainer = SyncedStore.makeContainer()
    #if os(iOS)
    @State private var watchBridge = WatchBridge()
    @State private var glasses = GlassesController()
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(coach)
                .environment(account)
                #if os(iOS)
                .environment(glasses)
                .onOpenURL { glasses.handle(url: $0) }
                #endif
                .task { await account.observeAuthentication() }
                .onChange(of: account.displayName) { _, value in model.signedInPlayerName = value }
                .onChange(of: account.isSignedIn) { _, value in coach.setSignedIn(value) }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await account.syncPendingStats(in: container.mainContext)
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
                .tint(.accentColor)
                .onAppear {
                    model.modelContext = container.mainContext
                    model.signedInPlayerName = account.displayName
                    coach.connect(to: model)
                    coach.useTransport { await account.museTransport() }
                    coach.setSignedIn(account.isSignedIn)
                    #if os(iOS)
                    watchBridge.connect(to: model, account: account)
                    glasses.connect(to: model, account: account)
                    #endif
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        #endif

        #if os(macOS)
        Settings { AppSettingsView().frame(width: 420) }
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("selectedTab") private var tab = "live"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Live", systemImage: "figure.tennis", value: "live") { NavigationStack { LiveView() } }
            Tab("Score", systemImage: "trophy", value: "score") { NavigationStack { ScoreView() } }
            Tab("Together", systemImage: "person.2", value: "together") { NavigationStack { SharedSessionView() } }
            Tab("History", systemImage: "clock.arrow.circlepath", value: "history") { HistoryView() }
            Tab("Insights", systemImage: "sparkles", value: "insights") { NavigationStack { InsightsView() } }
            Tab("Racket", systemImage: "sensor.tag.radiowaves.forward", value: "racket") { NavigationStack { RacketView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

#if os(macOS)
/// Mac Settings window (⌘,). The same toggle lives in the Racket tab on iPhone.
struct AppSettingsView: View {
    @AppStorage(UnitSystem.storageKey) private var useMetric = false

    var body: some View {
        Form {
            Picker("Units", selection: $useMetric) {
                Text("Imperial (mph, in)").tag(false)
                Text("Metric (km/h, cm)").tag(true)
            }
            .pickerStyle(.radioGroup)
            LabeledContent("iCloud sync", value: SyncedStore.statusText)
        }
        .formStyle(.grouped)
    }
}
#endif
