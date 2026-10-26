import Foundation
import HealthKit
import Observation

/// Runs a Tennis workout on the Watch while a session is active: live heart rate and calories,
/// saved to Apple Health when the session ends.
@MainActor
@Observable
final class WorkoutManager: NSObject {
    var heartRate: Double = 0
    var activeCalories: Double = 0
    var isRunning = false

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var heartRateSum: Double = 0
    private var heartRateCount: Double = 0
    var averageHeartRate: Double { heartRateCount > 0 ? heartRateSum / heartRateCount : 0 }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned)]
        try? await store.requestAuthorization(toShare: share, read: read)
    }

    func start() async {
        guard !isRunning else { return }
        await requestAuthorization()
        let config = HKWorkoutConfiguration()
        config.activityType = .tennis
        config.locationType = .outdoor
        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            builder.delegate = self
            self.session = session
            self.builder = builder
            heartRateSum = 0
            heartRateCount = 0
            let start = Date()
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() async {
        guard let session, let builder else { return }
        session.end()
        try? await builder.endCollection(at: Date())
        _ = try? await builder.finishWorkout()
        self.session = nil
        self.builder = nil
        isRunning = false
    }

    fileprivate func update(_ stats: HKStatistics) {
        switch stats.quantityType {
        case HKQuantityType(.heartRate):
            if let bpm = stats.mostRecentQuantity()?.doubleValue(for: .count().unitDivided(by: .minute())) {
                heartRate = bpm
                heartRateSum += bpm
                heartRateCount += 1
            }
        case HKQuantityType(.activeEnergyBurned):
            activeCalories = stats.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? activeCalories
        default: break
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let q = type as? HKQuantityType, let stats = workoutBuilder.statistics(for: q) else { continue }
            Task { @MainActor in self.update(stats) }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
