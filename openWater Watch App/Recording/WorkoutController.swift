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
    /// When collection began, and whether a single beat has ever landed.
    ///
    /// HealthKit will not say whether a *read* was granted — the API refuses
    /// to reveal it on purpose, so that an app cannot infer what a rider
    /// declined — which means silence is the only signal there is. Forty
    /// seconds of a running workout with no heart rate is either a permission
    /// that was never given or a watch nobody is wearing, and both mean the
    /// same thing to somebody staring at a blank number: this session will
    /// have none.
    private(set) var collectionStartedAt: Date?
    private(set) var hasEverReadHeartRate = false

    /// Whether to stop pretending a number is coming.
    var heartRateUnavailable: Bool {
        guard !hasEverReadHeartRate, let started = collectionStartedAt else { return false }
        return Date().timeIntervalSince(started) > 40
    }
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

    /// Whether Health will actually hand a heartbeat over, asked directly.
    ///
    /// Two facts, because neither is enough alone. `statusForAuthorizationRequest`
    /// says whether the rider has ever been asked — it reports `shouldRequest`
    /// until the prompt is answered — but it will not say what they answered,
    /// because HealthKit refuses to reveal a denied *read* to the app that was
    /// denied. So the second fact is empirical: ask for one heart-rate sample,
    /// any heart-rate sample. A refused read returns an empty result rather
    /// than an error, so a sample coming back is proof of access, and no
    /// sample on a watch somebody has been wearing means the answer was no.
    ///
    /// Static, and on its own store, so the phone's question can be answered
    /// without a recording in progress.
    static func heartRateProbe() async -> (asked: Bool, canRead: Bool) {
        guard HKHealthStore.isHealthDataAvailable() else { return (false, false) }
        let store = HKHealthStore()
        let share: Set<HKSampleType> = [HKQuantityType.workoutType(), HKSeriesType.workoutRoute()]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate)]
        let status = try? await store.statusForAuthorizationRequest(toShare: share, read: read)
        let asked = status != .shouldRequest

        let canRead: Bool = await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.heartRate),
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { @Sendable _, samples, _ in
                continuation.resume(returning: samples?.isEmpty == false)
            }
            store.execute(query)
        }
        return (asked, canRead)
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

        collectionStartedAt = startDate
        hasEverReadHeartRate = false
        session.startActivity(with: startDate)
        // Same hazard as MotionProvider: HealthKit's completion handler is not
        // Sendable in the SDK, so a closure written inside this class inherits
        // main-actor isolation and then gets called on HealthKit's own queue.
        builder.beginCollection(withStart: startDate) { @Sendable success, error in
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
        collectionStartedAt = nil
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
            if let newHeartRate {
                self.heartRate = newHeartRate
                self.hasEverReadHeartRate = true
            }
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
