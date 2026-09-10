import Foundation
import HealthKit
import os

/// Proves the watch can collect a heartbeat by collecting one.
///
/// `WorkoutController.heartRateProbe` answers a different question than it
/// looks like it answers. It reads the most recent heart-rate sample in the
/// store, which the watch writes on its own all day — so it establishes that
/// openWater is *allowed* to read heart rate, and nothing more. A workout
/// session that fails to start, or a builder that never collects, passes that
/// probe green and still records a session with no beat in it.
///
/// So this walks the same path a real session walks: a workout session, a live
/// builder, the same data source, waiting for the same delegate callback. If a
/// beat comes back, the path works — not in principle, but just now, on this
/// watch, on this wrist.
///
/// Nothing survives it. The workout is discarded rather than finished, so
/// proving the sensor works does not leave a one-minute "Other" workout in
/// Health for every rider who taps the button.
@MainActor
final class HeartRateCheck: NSObject {

    nonisolated private static let logger = Logger(subsystem: "com.laan.labs.openWater",
                                                   category: "HeartRateCheck")

    struct Result: Sendable {
        /// Whether the workout session started at all. False is the loud
        /// answer: it means a real session would not have recorded either.
        var started: Bool
        /// The beat, if one arrived inside the window.
        var beat: Double?
        /// Why it could not start, when it could not.
        var failure: String?
    }

    /// Run a check on its own store and throw the whole thing away afterwards.
    ///
    /// `seconds` is the wait for the first beat. The sensor takes a few
    /// seconds to spin up from cold, and the reply travels back over
    /// `WCSession`, so this stays well inside the time the phone is prepared
    /// to hold a message open.
    static func run(waiting seconds: TimeInterval = 15) async -> Result {
        await HeartRateCheck().measure(waiting: seconds)
    }

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var continuation: CheckedContinuation<Result, Never>?
    private var deadline: Task<Void, Never>?

    /// Kept as state rather than passed to `settle`, so a beat that lands in
    /// the gap between collection starting and the continuation being stored
    /// is still the answer rather than being dropped on the floor.
    private var observedBeat: Double?

    private func measure(waiting seconds: TimeInterval) async -> Result {
        guard HKHealthStore.isHealthDataAvailable() else {
            return Result(started: false, beat: nil,
                          failure: "This watch has no Health data available.")
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        // Indoor: proving the heartbeat should not also wake the receiver and
        // spend a rider's battery on a fix nobody asked for.
        configuration.locationType = .indoor

        do {
            let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: store,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let now = Date()
            session.startActivity(with: now)
            // Same hazard as WorkoutController: HealthKit's completion handler
            // is not Sendable in the SDK, so a closure written here inherits
            // main-actor isolation and is then called on HealthKit's queue.
            builder.beginCollection(withStart: now) { @Sendable _, error in
                if let error {
                    Self.logger.error("check beginCollection failed: \(error.localizedDescription)")
                }
            }
        } catch {
            // The interesting failure. A session that cannot be created is
            // exactly what leaves a rider with no heartbeat and no warning.
            Self.logger.error("check session failed to start: \(error.localizedDescription)")
            return Result(started: false, beat: nil, failure: error.localizedDescription)
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.settle()
            }
        }
    }

    /// Resume once, tear down always.
    private func settle(failure: String? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil

        session?.end()
        // Discarded, not finished: this was a question, not a workout.
        builder?.discardWorkout()
        session = nil
        builder = nil

        continuation.resume(returning: Result(started: failure == nil,
                                              beat: observedBeat,
                                              failure: failure))
    }
}

// MARK: - Delegates

extension HeartRateCheck: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {}

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Self.logger.error("check session failed: \(error.localizedDescription)")
        Task { @MainActor in self.settle(failure: error.localizedDescription) }
    }
}

extension HeartRateCheck: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let type = HKQuantityType(.heartRate)
        guard collectedTypes.contains(type),
              let statistics = workoutBuilder.statistics(for: type),
              let quantity = statistics.mostRecentQuantity() else { return }

        let unit = HKUnit.count().unitDivided(by: .minute())
        let beat = quantity.doubleValue(for: unit)
        Task { @MainActor in
            self.observedBeat = beat
            // The first beat is the whole answer; there is no reason to hold a
            // workout session open for the rest of the window.
            self.settle()
        }
    }
}
