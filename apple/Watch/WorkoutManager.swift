import Foundation
import HealthKit
import Observation

/// A live tennis workout supplies HealthKit's energy/exercise samples used by Activity rings.
@MainActor
@Observable
final class WorkoutManager: NSObject {
    private(set) var heartRate: Double = 0
    private(set) var activeCalories: Double = 0
    private(set) var averageHeartRate: Double = 0
    private(set) var isRunning = false
    private(set) var isTransitioning = false
    private(set) var statusMessage: String?
    var onFinished: ((UUID?, Double, Double) -> Void)?
    private var desiredID: UUID?
    private var activeID: UUID?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var wantsWorkout = false
    @ObservationIgnored private var transition: Task<Void, Never>?

    /// Serialize start/stop, including a stop received while the authorization sheet is open.
    func setActive(_ active: Bool, recordID: UUID? = nil) {
        wantsWorkout = active
        if active { desiredID = recordID }
        guard transition == nil else { return }
        transition = Task {
            isTransitioning = true
            defer { isTransitioning = false; transition = nil }
            while wantsWorkout != isRunning || (wantsWorkout && activeID != desiredID) {
                if isRunning { await stop() }
                else if wantsWorkout {
                    if !(await start()) { break }
                }
            }
        }
    }

    private func start() async -> Bool {
        heartRate = 0; activeCalories = 0; averageHeartRate = 0; statusMessage = nil
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "Health is unavailable on this Watch."
            return false
        }
        do {
            let energy = HKQuantityType(.activeEnergyBurned)
            try await store.requestAuthorization(toShare: [HKObjectType.workoutType(), energy],
                                                 read: [HKQuantityType(.heartRate), energy])
            guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                statusMessage = "Allow Tennis Buddee to save workouts in Health settings."
                return false
            }
            guard wantsWorkout else { return false }
            activeID = desiredID
            let config = HKWorkoutConfiguration()
            config.activityType = .tennis
            config.locationType = .unknown // Supports indoor and outdoor courts.
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            builder.delegate = self
            session.delegate = self
            self.session = session; self.builder = builder
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            isRunning = true
            return true
        } catch {
            session?.end(); builder?.discardWorkout()
            session = nil; builder = nil; isRunning = false
            statusMessage = "Workout could not start: " + error.localizedDescription
            return false
        }
    }

    private func stop() async {
        guard let session, let builder else { isRunning = false; return }
        session.end()
        do {
            try await builder.endCollection(at: Date())
            if let stats = builder.statistics(for: HKQuantityType(.activeEnergyBurned)) { update(stats) }
            if let stats = builder.statistics(for: HKQuantityType(.heartRate)) { update(stats) }
            guard try await builder.finishWorkout() != nil else {
                throw NSError(domain: "Workout", code: 1, userInfo: [NSLocalizedDescriptionKey: "No workout was saved."])
            }
            statusMessage = "Tennis workout saved to Health."
        } catch { statusMessage = "Workout could not be saved: " + error.localizedDescription }
        onFinished?(activeID, averageHeartRate, activeCalories)
        self.session = nil; self.builder = nil; isRunning = false
    }

    fileprivate func update(_ stats: HKStatistics) {
        switch stats.quantityType {
        case HKQuantityType(.heartRate):
            let bpm = HKUnit.count().unitDivided(by: .minute())
            heartRate = stats.mostRecentQuantity()?.doubleValue(for: bpm) ?? heartRate
            averageHeartRate = stats.averageQuantity()?.doubleValue(for: bpm) ?? averageHeartRate
        case HKQuantityType(.activeEnergyBurned):
            activeCalories = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? activeCalories
        default: break
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate, HKWorkoutSessionDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let q = type as? HKQuantityType, let stats = workoutBuilder.statistics(for: q) else { continue }
            Task { @MainActor in
                guard self.builder === workoutBuilder else { return }
                self.update(stats)
            }
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                   from fromState: HKWorkoutSessionState, date: Date) {
        if toState == .ended {
            Task { @MainActor in
                guard self.session === workoutSession, self.wantsWorkout else { return }
                self.setActive(false)
            }
        }
    }
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.session === workoutSession else { return }
            self.statusMessage = "Workout interrupted: " + error.localizedDescription
            self.setActive(false)
        }
    }
}
