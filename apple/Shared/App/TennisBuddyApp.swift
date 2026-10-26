import SwiftData
import SwiftUI

@main
struct TennisBuddyApp: App {
    @State private var model = AppModel()
    @State private var coach = CoachModel()
    let container: ModelContainer = {
        let schema = Schema([SessionRecord.self, ShotRecord.self])
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: config)
    }()
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
                    #if os(iOS)
                    watchBridge.connect(to: model)
                    #endif
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
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
