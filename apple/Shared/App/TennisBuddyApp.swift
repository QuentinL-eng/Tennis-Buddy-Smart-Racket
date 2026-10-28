import RacketKit
import SwiftData
import SwiftUI

@main
struct TennisBuddyApp: App {
    @State private var model = AppModel()
    @State private var coach = CoachModel()
    let container: ModelContainer = SyncedStore.makeContainer()
    #if os(iOS)
    @State private var watchBridge = WatchBridge()
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(coach)
                .tint(.accentColor)
                .onAppear {
                    model.modelContext = container.mainContext
                    coach.connect(to: model)
                    #if os(iOS)
                    watchBridge.connect(to: model)
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
