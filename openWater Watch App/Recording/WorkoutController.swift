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

    /// Where a fault goes so it reaches the rider, not just the log.
    ///
    /// Three failures were caught in this file and written to os_log, and a
    /// rider's session then arrived on the phone with no heart rate and a
    /// guess about permissions. The recorder wires this to the engine, which
    /// writes it onto the session — see `Session.recordingIssues`.
    var onIssue: ((String) -> Void)?

    /// Fired once, the moment HealthKit reports the session `.running`.
    ///
    /// This is the only moment watchOS will grant Water Lock for a workout,
    /// and it is *not* the moment `startActivity` returns — the transition is
    /// asynchronous, and asking before it has happened is asking for nothing.
    var onRunning: (() -> Void)?

    /// Whether the session ever got there. A session that never does costs
    /// heart rate, Water Lock, and the Health entry, and used to cost them
    /// silently.
    private(set) var hasEverRun = false

    nonisolated private func report(_ text: String) {
        Self.logger.error("\(text, privacy: .public)")
        Task { @MainActor in self.onIssue?(text) }
    }

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
        // Only for a swim. Set on anything else, HealthKit refuses to create
        // the session at all — "Swimming location should not be set for non
        // swimming activities" — and this was set on every session. The
        // failure was caught and logged and nothing else, so every watch
        // recording this app ever made ran without a workout session: no
        // heart rate, no Water Lock, no entry in Health, and the sensors kept
        // alive only by background location. A rider's own phone reported it
        // the first time the error was written onto the session instead of
        // the log.
        if configuration.activityType == .swimming {
            configuration.swimmingLocationType = .openWater
        }

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
        hasEverRun = false
        session.startActivity(with: startDate)
        // Same hazard as MotionProvider: HealthKit's completion handler is not
        // Sendable in the SDK, so a closure written inside this class inherits
        // main-actor isolation and then gets called on HealthKit's own queue.
        builder.beginCollection(withStart: startDate) { @Sendable [weak self] success, error in
            if let error {
                self?.report("Health would not start collecting: \(error.localizedDescription)")
            } else if !success {
                self?.report("Health declined to start collecting, and gave no reason.")
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

        if !hasEverRun {
            // The one that explains everything at once. Not a permission
            // problem and not a sensor problem: HealthKit was asked to start
            // and never said it had.
            onIssue?("The workout session never became active (last state: \(state.rawValue)). Without it there is no heart rate, Water Lock cannot be enabled, and no workout is written to Health.")
        } else if !hasEverReadHeartRate, let started = collectionStartedAt,
           endDate.timeIntervalSince(started) > 40 {
            // Not a permission problem — that is refused earlier and reported
            // as such. The session started, collection started, the watch was
            // worn, and Health handed over no beat. Said plainly so the phone
            // does not have to guess.
            onIssue?("The workout ran for the whole session and Health delivered no heart rate. Permission was granted; the sensor or the workout never produced a reading.")
        }

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
            if toState == .running, !self.hasEverRun {
                self.hasEverRun = true
                self.onRunning?()
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        report("The workout session failed: \(error.localizedDescription)")
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

            switch HKQuantityTypeIdentifier(rawValue: quantityType.identifier) {
            case .heartRate:
                let unit = HKUnit.count().unitDivided(by: .minute())
                newHeartRate = statistics.mostRecentQuantity()?.doubleValue(for: unit)
            case .activeEnergyBurned:
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
