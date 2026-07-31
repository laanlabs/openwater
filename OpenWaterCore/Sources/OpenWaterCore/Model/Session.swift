import Foundation

/// A recorded session: the track plus everything the rider tells us about it.
public struct Session: Sendable, Codable, Identifiable {

    public var id: UUID

    public var sport: Sport
    public var startDate: Date
    public var endDate: Date

    public var track: Track

    /// Free-text notes.
    public var notes: String

    /// Gear used, by identifier into the gear locker.
    public var gearIDs: [UUID]

    /// Named spot, if the session was matched to one.
    public var spotID: UUID?
    public var spotName: String?

    /// Wind for the session — estimated on import, overridable by the rider.
    public var wind: Wind?

    /// Local filenames of attached photos, relative to the session's media
    /// directory. Never absolute paths: those break the moment the container
    /// identifier changes between launches.
    public var photoNames: [String]

    /// Device that recorded it, for the diagnostics screen.
    public var deviceModel: String?
    public var appVersion: String?

    /// Battery level at start and end, 0–1. Recording this is what lets the app
    /// tell a rider honestly why their track ends where it does.
    public var startBattery: Double?
    public var endBattery: Double?

    /// Cached analysis. Recomputed when `analysisVersion` no longer matches the
    /// current engine.
    public var summary: SessionSummary?

    public var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    public init(
        id: UUID = UUID(),
        sport: Sport,
        startDate: Date,
        endDate: Date,
        track: Track,
        notes: String = "",
        gearIDs: [UUID] = [],
        spotID: UUID? = nil,
        spotName: String? = nil,
        wind: Wind? = nil,
        photoNames: [String] = [],
        deviceModel: String? = nil,
        appVersion: String? = nil,
        startBattery: Double? = nil,
        endBattery: Double? = nil,
        summary: SessionSummary? = nil
    ) {
        self.id = id
        self.sport = sport
        self.startDate = startDate
        self.endDate = endDate
        self.track = track
        self.notes = notes
        self.gearIDs = gearIDs
        self.spotID = spotID
        self.spotName = spotName
        self.wind = wind
        self.photoNames = photoNames
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.startBattery = startBattery
        self.endBattery = endBattery
        self.summary = summary
    }
}

/// Everything computed from a track, cached so the session list is instant.
///
/// Stamped with `analysisVersion`: when a detector changes, existing summaries
/// become stale rather than silently wrong, and the app can offer to recompute.
/// A number a rider screenshotted last season should always be traceable to the
/// code that produced it.
public struct SessionSummary: Hashable, Sendable, Codable {

    /// Bumped whenever any analyzer's behaviour changes.
    public static let currentVersion = 1

    public let analysisVersion: Int

    // MARK: Basics

    public let duration: TimeInterval
    public let movingTime: TimeInterval
    public let distance: Double
    public let maxSpeed: Double
    public let averageSpeed: Double
    /// Average over moving time only — the number that is not dragged down by
    /// sitting on the beach with the recorder running.
    public let averageMovingSpeed: Double

    public let quality: TrackQuality
    public let speedSource: SpeedSource

    // MARK: Categories

    /// Results for every configured speed category, in display order.
    public let speedResults: [SpeedResult]

    // MARK: Structure

    public let runs: [Run]
    public let maneuvers: [Maneuver]
    public let maneuverSummary: ManeuverSummary
    public let flights: [Flight]
    public let foil: FoilSummary
    public let jumps: [Jump]
    public let jumpSummary: JumpSummary
    public let downwind: DownwindSummary

    /// Per-sample ride state, and the drawable segments derived from it.
    /// These are what make an overlapping track legible on a map.
    public let states: [RideState]
    public let segments: [StateSegment]

    public let fallSummary: FallSummary

    /// The session unrolled into lanes — the readable alternative to the map.
    public let ribbon: SessionRibbon

    // MARK: Wind

    public let wind: Wind?
    public let polar: PolarAnalysis?

    // MARK: Physiology

    public let averageHeartRate: Double?
    public let maxHeartRate: Double?
    public let activeEnergyKilojoules: Double?

    public init(
        analysisVersion: Int = SessionSummary.currentVersion,
        duration: TimeInterval,
        movingTime: TimeInterval,
        distance: Double,
        maxSpeed: Double,
        averageSpeed: Double,
        averageMovingSpeed: Double,
        quality: TrackQuality,
        speedSource: SpeedSource,
        speedResults: [SpeedResult],
        runs: [Run],
        maneuvers: [Maneuver],
        maneuverSummary: ManeuverSummary,
        flights: [Flight],
        foil: FoilSummary,
        jumps: [Jump],
        jumpSummary: JumpSummary,
        downwind: DownwindSummary,
        states: [RideState] = [],
        segments: [StateSegment] = [],
        fallSummary: FallSummary = .none,
        ribbon: SessionRibbon = SessionRibbon(
            lanes: [], connectors: [], maxLaneDistance: 0, maxLaneDuration: 0, maxSpeed: 0
        ),
        wind: Wind?,
        polar: PolarAnalysis?,
        averageHeartRate: Double? = nil,
        maxHeartRate: Double? = nil,
        activeEnergyKilojoules: Double? = nil
    ) {
        self.analysisVersion = analysisVersion
        self.duration = duration
        self.movingTime = movingTime
        self.distance = distance
        self.maxSpeed = maxSpeed
        self.averageSpeed = averageSpeed
        self.averageMovingSpeed = averageMovingSpeed
        self.quality = quality
        self.speedSource = speedSource
        self.speedResults = speedResults
        self.runs = runs
        self.maneuvers = maneuvers
        self.maneuverSummary = maneuverSummary
        self.flights = flights
        self.foil = foil
        self.jumps = jumps
        self.jumpSummary = jumpSummary
        self.downwind = downwind
        self.states = states
        self.segments = segments
        self.fallSummary = fallSummary
        self.ribbon = ribbon
        self.wind = wind
        self.polar = polar
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.activeEnergyKilojoules = activeEnergyKilojoules
    }

    /// Whether this summary was produced by the current engine.
    public var isCurrent: Bool { analysisVersion == Self.currentVersion }

    /// Look up one category's result.
    public func result(for category: SpeedCategory) -> SpeedResult? {
        speedResults.first { $0.category == category }
    }

    /// The best run of the session by average speed.
    public var bestRun: Run? {
        runs.max { $0.averageSpeed < $1.averageSpeed }
    }
}
