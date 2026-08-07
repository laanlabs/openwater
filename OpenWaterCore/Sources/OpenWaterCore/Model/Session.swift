import Foundation

/// A recorded session: the track plus everything the rider tells us about it.
public struct Session: Sendable, Codable, Identifiable {

    public var id: UUID

    public var sport: Sport
    public var startDate: Date
    public var endDate: Date

    public var track: Track

    /// What the rider calls this session.
    ///
    /// Optional on purpose: most sessions never get one, and a required title
    /// would be a chore at the exact moment somebody is cold and wants to stop
    /// fiddling with their phone. When it is empty the UI falls back to the
    /// spot, then to the sport.
    public var title: String?

    /// Free-text notes.
    public var notes: String

    /// Why the rider went out — "For fun", "Training", "Race". Free text with
    /// suggestions rather than a fixed list, because the useful labels differ
    /// by discipline and nobody's session fits somebody else's taxonomy.
    public var purpose: String?

    /// How it felt, 1 (rough) to 5 (great).
    ///
    /// Worth recording precisely because it is the one thing GPS cannot: two
    /// sessions with identical numbers can be a breakthrough and a miserable
    /// slog, and a season of these next to the speeds is how a rider notices
    /// which conditions actually suit them.
    public var feeling: Int?

    /// Speed this rider counts as flying, m/s. `nil` uses the sport default.
    /// See `SessionAnalyzer.Configuration.foilTakeoffSpeed`.
    public var foilTakeoffSpeed: Double?

    /// Gear used, by identifier into the gear locker.
    public var gearIDs: [UUID]

    /// Named spot, if the session was matched to one.
    public var spotID: UUID?
    public var spotName: String?

    /// Significant swell height the rider reckoned, metres.
    ///
    /// Never measured, never inferred — GPS cannot see a wave. It is here
    /// because on a downwinder it is the number that explains the session:
    /// the same wind over knee-high chop and over head-high bumps are two
    /// different days, and a season of these next to the speeds is how a
    /// rider learns which conditions actually suit them.
    public var swellHeight: Double?

    /// Wind for the session — estimated on import, overridable by the rider.
    ///
    /// Prefer `effectiveWind` when reading: the analysis carries its own copy,
    /// and these two can disagree if a session was built without threading this
    /// one through.
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

    /// Which part of the recording counts as the session.
    ///
    /// Recording never stops for a break — see `SessionTrim`. The boundaries are
    /// moved afterwards instead, and stored rather than applied destructively.
    public var trim: SessionTrim = .none

    /// Every fix as recorded, before the trim.
    ///
    /// Only populated once a trim is in force. Without one the track already
    /// *is* the whole recording, and keeping a second copy would double the
    /// archive for nothing.
    public var untrimmedPoints: [TrackPoint]?

    /// Every fix that was recorded, trim or no trim.
    ///
    /// This is what a trim is recomputed from, which is what makes trimming
    /// reversible: nothing is ever deleted.
    public var rawPoints: [TrackPoint] { untrimmedPoints ?? track.points }

    /// Cached analysis. Recomputed when `analysisVersion` no longer matches the
    /// current engine.
    public var summary: SessionSummary?

    public var duration: TimeInterval { endDate.timeIntervalSince(startDate) }

    /// The wind in force for this session.
    ///
    /// A session carries wind in two places — its own field, which is the
    /// rider's input, and the analysis, which is what the numbers were actually
    /// computed against. They should agree, but a session built without
    /// threading the first one through will have it nil while the summary knows
    /// perfectly well what the wind was. Reading through here means callers
    /// cannot accidentally see "no wind" on a session that plainly has one.
    public var effectiveWind: Wind? { wind ?? summary?.wind }

    /// The flying threshold in force for this session.
    public var effectiveFoilTakeoffSpeed: Double {
        foilTakeoffSpeed ?? sport.thresholds.foilTakeoffSpeed
    }

    /// What to show as this session's name.
    ///
    /// Falls back through title → spot → sport, so there is always something
    /// sensible to display and no screen has to invent its own rule.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if let spotName, !spotName.trimmingCharacters(in: .whitespaces).isEmpty { return spotName }
        return sport.displayName
    }

    /// A secondary line for the same places — the spot when a title is set,
    /// otherwise the sport, and nothing when that would just repeat the title.
    public var displaySubtitle: String? {
        let name = displayTitle
        if let spotName, !spotName.isEmpty, spotName != name { return spotName }
        if sport.displayName != name { return sport.displayName }
        return nil
    }

    public init(
        id: UUID = UUID(),
        sport: Sport,
        startDate: Date,
        endDate: Date,
        track: Track,
        title: String? = nil,
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
        trim: SessionTrim = .none,
        untrimmedPoints: [TrackPoint]? = nil,
        purpose: String? = nil,
        feeling: Int? = nil,
        foilTakeoffSpeed: Double? = nil,
        swellHeight: Double? = nil,
        summary: SessionSummary? = nil
    ) {
        self.id = id
        self.sport = sport
        self.startDate = startDate
        self.endDate = endDate
        self.track = track
        self.title = title
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
        self.trim = trim
        self.untrimmedPoints = untrimmedPoints
        self.purpose = purpose
        self.feeling = feeling
        self.foilTakeoffSpeed = foilTakeoffSpeed
        self.swellHeight = swellHeight
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
    /// 2: constant course channels (Waterspeed's all-zero placeholder) are
    /// ignored and courses derived from positions, which un-flattens the
    /// polar and every wind angle on affected imports.
    /// 3: alpha takes the best segment of *at most* its cap (the community
    /// rule) instead of exactly the cap; Alpha 1 km added; polar carries
    /// per-tack mean headings and the both-tacks beat/run VMG.
    /// 4: the beat/run carry their leg count and working angle.
    /// Bump this whenever *any* detector's behaviour changes, not only when a
    /// field is added.
    ///
    /// `upToDateSession` trusts this number: a stored summary whose version
    /// matches is returned untouched, so a detection change without a bump is
    /// invisible on every session a rider already has. That has now happened
    /// three times in one day — the glide floor, the pump threshold, and the
    /// smoothness bar — each time looking like the fix had not worked.
    public static let currentVersion = 10

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

    /// Whether this was a downwind run, a crossing, or an afternoon of laps —
    /// and, for a shuttle day, each run of it separately.
    ///
    /// Stored optional and read non-optional, and that is not a style choice.
    /// Swift's synthesised decoder does **not** fall back to a property's
    /// default when a key is absent — it throws — so adding a non-optional
    /// field to this struct makes every archive a rider already has
    /// undecodable. That shipped once: sessions written by earlier builds
    /// failed to decode, the failure was swallowed by a `try?`, and every
    /// session sat on "Loading session…" for ever. Anything added here from
    /// now on is optional in storage.
    private let storedShape: SessionShape?

    public var shape: SessionShape { storedShape ?? .empty }

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
        shape: SessionShape = .empty,
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
        self.storedShape = shape
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
