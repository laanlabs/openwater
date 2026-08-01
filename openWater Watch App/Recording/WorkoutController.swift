import CoreLocation
import Foundation
import HealthKit
import OpenWaterCore
import os

/// Owns the `HKWorkoutSession`.
///
/// This is not an optional nicety on watchOS — it is the mechanism. An app that
/// is merely backgrounded stops receiving location updates within seconds of the
/// wrist dropping. An app running an active workout session keeps its sensors
/// alive for hours with the screen off. So the workout session is what makes a
/// three-hour downwinder recordable at all, and everything else is arranged
/// around keeping it healthy.
///
/// It also earns its keep twice over: heart rate and active energy arrive for
/// free, and the finished session lands in Health as a real workout with its
/// route, so it counts toward the rings like any other activity.
@MainActor
@Observable
final class WorkoutController: NSObject {

    // Nonisolated so the HealthKit completion handlers and the nonisolated
    // delegate methods — which are the ones that most need to log — can reach
    // it. A Logger is Sendable; only the inferred isolation was in the way.
    nonisolated private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Workout")

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var routeBuilder: HKWorkoutRouteBuilder?

    private(set) var state: HKWorkoutSessionState = .notStarted
    private(set) var heartRate: Double?
    private(set) var activeEnergyKilocalories: Double = 0
    private(set) var isAuthorized = false

    /// Health is unavailable on some configurations; recording must still work.
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: - Authorization

    func requestAuthorization() async {
        guard isAvailable else { return }

        let share: Set<HKSampleType> = [
            HKQuantityType.workoutType(),
            HKSeriesType.workoutRoute(),
        ]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKObjectType.activitySummaryType(),
        ]

        do {
            try await store.requestAuthorization(toShare: share, read: read)
            isAuthorized = true
        } catch {
            // A refusal is not fatal. The rider loses heart rate and the Health
            // entry, not their track.
            Self.logger.notice("health authorization declined: \(error.localizedDescription)")
            isAuthorized = false
        }
    }

    // MARK: - Lifecycle

    func start(sport: Sport, startDate: Date) throws {
        guard isAvailable else { return }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = sport.healthKitActivityType
        configuration.locationType = .outdoor
        configuration.swimmingLocationType = .openWater

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
        self.routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)

        session.startActivity(with: startDate)
        builder.beginCollection(withStart: startDate) { success, error in
            if let error {
                Self.logger.error("beginCollection failed: \(error.localizedDescription)")
            }
        }
    }

    func pause() {
        session?.pause()
    }

    func resume() {
        session?.resume()
    }

    /// Finish the workout and save it with its route.
    ///
    /// Deliberately tolerant: if saving the route fails the workout is still
    /// saved, and if the whole Health write fails the caller still has the
    /// track. Health is a destination, never the source of truth.
    func finish(endDate: Date, route: [CLLocation]) async {
        guard let session, let builder else { return }

        session.stopActivity(with: endDate)
        session.end()

        do {
            try await builder.endCollection(at: endDate)
            let workout = try await builder.finishWorkout()

            if let workout, !route.isEmpty, let routeBuilder {
                try? await routeBuilder.insertRouteData(route)
                try? await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
        } catch {
            Self.logger.error("failed to save workout: \(error.localizedDescription)")
        }

        self.session = nil
        self.builder = nil
        self.routeBuilder = nil
    }

    func discard() {
        session?.end()
        builder?.discardWorkout()
        session = nil
        builder = nil
        routeBuilder = nil
    }
}

// MARK: - Delegates

extension WorkoutController: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.state = toState
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Self.logger.error("workout session failed: \(error.localizedDescription)")
    }
}

extension WorkoutController: HKLiveWorkoutBuilderDelegate {

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        var newHeartRate: Double?
        var newEnergy: Double?

        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType,
                  let statistics = workoutBuilder.statistics(for: quantityType) else { continue }

            switch quantityType {
            case HKQuantityType(.heartRate):
                let unit = HKUnit.count().unitDivided(by: .minute())
                newHeartRate = statistics.mostRecentQuantity()?.doubleValue(for: unit)
            case HKQuantityType(.activeEnergyBurned):
                newEnergy = statistics.sumQuantity()?.doubleValue(for: .kilocalorie())
            default:
                break
            }
        }

        Task { @MainActor in
            if let newHeartRate { self.heartRate = newHeartRate }
            if let newEnergy { self.activeEnergyKilocalories = newEnergy }
        }
    }
}

// MARK: - Sport mapping

extension Sport {
    /// The closest HealthKit activity for each discipline.
    ///
    /// HealthKit has no wingfoil or parawing type, so those map to
    /// `.surfingSports`, which is what Apple's own Workout app uses for wind and
    /// wave sports and gives the right energy model.
    var healthKitActivityType: HKWorkoutActivityType {
        switch self {
        case .wingfoil, .parawing, .windsurf, .windfoil, .kitesurf, .kitefoil, .prone:
            .surfingSports
        case .sail:
            .sailing
        case .downwindSUP, .sup:
            .paddleSports
        case .kayak:
            .paddleSports
        case .efoil, .tow, .other:
            .other
        }
    }
}
