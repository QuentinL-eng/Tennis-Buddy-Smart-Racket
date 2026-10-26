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

    init() {
        // `--coach-selftest`: load Gemma, coach a sample session, print the result, quit. Used to verify the model.
        if CommandLine.arguments.contains("--coach-selftest") {
            Task { @MainActor in
                let coach = CoachModel()
                let start = Date()
                await coach.loadGemma()
                print("Gemma state: \(coach.state) after \(Int(Date().timeIntervalSince(start)))s")
                let session = SessionRecord()
                session.endDate = session.startDate.addingTimeInterval(1500)
                session.shotRecords = CoachSelfTest.sampleShots().map { ShotRecord(metrics: $0) }
                let t = Date()
                print(await coach.summarize(session))
                print("Generated in \(String(format: "%.1f", Date().timeIntervalSince(t)))s with \(coach.engineName)")
                exit(0)
            }
        }
    }

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
