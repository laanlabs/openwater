import CoreLocation
import MapKit
import OpenWaterCore
import SwiftUI

/// The session map, drawn so it can actually be read.
///
/// A wing session is dozens of passes through the same water. Drawn as one
/// speed-coloured line it is a scribble — every pass sits on top of every other
/// and nothing is distinguishable. Three things fix that, and this view does all
/// three:
///
/// - **Ride state changes how a stretch is drawn**, not just its colour.
///   Flights are thick and opaque, riding is thinner, slow and stopped fade to a
///   faint ghost. That alone separates the signal from the paddling-about.
/// - **Falls get a marker.** They are the events you look for, and a break in a
///   line is not something the eye finds in a tangle.
/// - **Run isolation.** Selecting one run drops every other to a ghost layer.
///   Stepping through runs one at a time is the single biggest legibility win
///   there is, because it removes the overlap entirely.
struct TrackMapView: View {

    let session: Session
    let summary: SessionSummary

    /// The stretch of track to isolate, as sample indices. `nil` shows all.
    ///
    /// A range rather than a run identity, which is what this used to be and
    /// why isolation barely worked. A `StateSegment` is only tagged with a
    /// run when it sits *entirely inside* one, and most of them straddle a
    /// boundary — on test-8 only 38 of 98 segments carry a run at all, across
    /// 12 of the 73 runs. Matching on that identity drew a fraction of the
    /// selection, and for most runs drew nothing.
    ///
    /// A range asks the question the rider is actually asking — show me this
    /// piece of the track — and every segment can answer it.
    var isolatedRange: ClosedRange<Int>?

    /// Highlight a specific time range — used to show where a record was set.
    var highlight: ClosedRange<TimeInterval>?

    var showFalls: Bool = true
    var showManeuvers: Bool = false

    /// Only draw stretches at or above this speed, m/s.
    var minimumSpeed: Double = 0

    /// Only draw stretches spent flying.
    var foilingOnly: Bool = false

    /// Which ride states to draw. The point of separating flying from the rest
    /// is that a foil session's track is two different activities on top of
    /// each other, and looking at either one alone is far more readable than
    /// looking at both.
    var foilFilter: FoilFilter = .everything

    /// Draw only up to this elapsed time. Used by the scrubber, so dragging
    /// through the session reveals it in order instead of showing the finished
    /// tangle all at once.
    var partialUpTo: TimeInterval?

    /// Where the scrubber is, marked on the track.
    var playhead: TimeInterval?

    /// The stretch a trim would keep, marked at both ends. Declared after
    /// `playhead` so the call sites read in the order the arguments appear.
    ///
    /// Dragging a handle on a chart tells a rider *when* they are cutting; only
    /// the map tells them *where*, which on a session of forty overlapping
    /// passes is the thing they actually need to see.
    var trimRange: ClosedRange<TimeInterval>?

    /// Which end the finger is on, drawn larger so it is findable in a tangle.
    var activeTrimEdge: TrimEdge?

    /// When true, `trimRange` is the stretch being *cut* rather than kept, so
    /// the track stays whole and the doomed part is struck through instead.
    var trimIsRemoval: Bool = false

    /// Base map. Satellite is worth having on water, where the standard map is
    /// a featureless blue field with nothing to orient by.
    var style: MapStyleOption = .standard

    /// Only for the peak-speed label. Everything else on the map is drawn, not
    /// written.
    var units: UnitPreferences = .default

    /// Called with the elapsed time of the nearest sample when the rider taps
    /// the track. Nil disables it.
    var onSeek: ((TimeInterval) -> Void)?

    @State private var camera: MapCameraPosition = .automatic

    /// The drawn track, rebuilt only when something that actually changes its
    /// shape changes — never while a trim handle is moving.
    @State private var bands: [SpeedBand] = []
    @State private var fullTrack: [CLLocationCoordinate2D] = []

    /// A thinned outline of the track, drawn while the coloured bands build.
    ///
    /// The bands are computed off the main actor, which keeps the app
    /// responsive and leaves the map blank for the second it takes on a long
    /// session — and a blank map reads as a session that failed to load. Every
    /// twentieth fix is enough to show the shape immediately; it costs a few
    /// hundred points and is thrown away the moment the real thing lands.
    @State private var outline: [CLLocationCoordinate2D] = []
    @State private var isDrawing = true

    private var showsGhostLayer: Bool {
        isolatedRange != nil || highlight != nil || foilingOnly
            || foilFilter != .everything || minimumSpeed > 0 || partialUpTo != nil
    }

    /// Everything the base layer depends on. `trimRange` is deliberately absent:
    /// the selection is drawn over the top instead of carved out of it, so a
    /// drag costs one polyline rather than a full rebuild.
    private struct BandKey: Equatable {
        let sessionID: UUID
        let isolatedRange: ClosedRange<Int>?
        let foilingOnly: Bool
        let foilFilter: FoilFilter
        let minimumSpeed: Double
        /// Quantised to the second. The scrubber moves continuously and the
        /// difference between two neighbouring frames is one sample.
        let partialUpTo: Int?
        let onDark: Bool
        let highlight: ClosedRange<TimeInterval>?
    }

    /// The ramp this session is coloured across, built from its own speeds so
    /// the whole sweep of colour lands on the range actually ridden.
    var speedScale: SpeedScale { SpeedScale(speeds: session.track.speed) }

    private var bandKey: BandKey {
        BandKey(
            sessionID: session.id,
            isolatedRange: isolatedRange,
            foilingOnly: foilingOnly,
            foilFilter: foilFilter,
            minimumSpeed: minimumSpeed,
            partialUpTo: partialUpTo.map { Int($0) },
            onDark: style.isDark,
            highlight: highlight
        )
    }

    public enum TrimEdge { case start, end }

    /// What counts as visible track.
    enum FoilFilter: String, CaseIterable, Identifiable {
        case everything = "Everything"
        case foiling = "On foil"
        case notFoiling = "Off foil"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .everything: "point.topleft.down.to.point.bottomright.curvepath"
            case .foiling: "airplane"
            case .notFoiling: "water.waves"
            }
        }
    }

    var body: some View {
        // The reader is only here for the tap: it is the one way to turn a
        // point on screen back into a coordinate, which is what makes the
        // track itself a control rather than a picture.
        MapReader { proxy in
            map(proxy: proxy)
        }
    }

    private func map(proxy: MapProxy) -> some View {
        Map(position: $camera) {
            // Ghost layer first, so the highlighted content draws over it.
            if showsGhostLayer {
                MapPolyline(coordinates: fullTrack)
                    .stroke(
                        style.isDark ? .white.opacity(0.28) : .gray.opacity(0.22),
                        lineWidth: 2
                    )
            }

            // The shape, while the colour is still being worked out.
            if isDrawing, !outline.isEmpty {
                MapPolyline(coordinates: outline)
                    .stroke(style.isDark ? .white.opacity(0.5) : .gray.opacity(0.45),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            // The base track. Everything about it is cached and none of it
            // depends on `trimRange`, so dragging a trim handle leaves this
            // layer byte-for-byte identical and SwiftUI has nothing to diff.
            // That is the whole performance story: it used to be several
            // hundred polylines rebuilt from ten thousand samples on every
            // frame of the drag.
            ForEach(bands) { band in
                MapPolyline(coordinates: band.coordinates)
                    .stroke(
                        band.colour,
                        style: StrokeStyle(
                            lineWidth: band.width,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }


            // The fastest moment of the session, marked.
            //
            // It is the number on the top of the summary and there was nothing
            // saying where it happened — so a rider could not go and look at
            // the run that produced it, or notice that it came from a spot they
            // know is a GPS blackspot.
            if let peak = maxSpeedCoordinate {
                Annotation("", coordinate: peak, anchor: .bottom) {
                    MaxSpeedMarker(
                        speed: summary.maxSpeed,
                        units: units,
                        onDark: style.isDark
                    )
                }
                .annotationTitles(.hidden)
            }

            if showFalls {
                ForEach(summary.fallSummary.falls) { fall in
                    Annotation(
                        "Fall",
                        coordinate: fall.coordinate.clCoordinate,
                        anchor: .center
                    ) {
                        FallMarker(fall: fall)
                    }
                    .annotationTitles(.hidden)
                }
            }

            if showManeuvers {
                ForEach(summary.maneuvers) { maneuver in
                    if let coordinate = session.track.points[safe: maneuver.startIndex]?.clCoordinate {
                        Annotation("", coordinate: coordinate, anchor: .center) {
                            ManeuverMarker(maneuver: maneuver)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }

            // What the edit would throw away, greyed over the top of the
            // track.
            //
            // Marking what is *kept* was tried first and does not work: on a
            // session of forty overlapping passes a highlight under the line
            // merges into one solid mass and the speed colours — the reason for
            // looking at the map — disappear. Dimming what goes leaves the kept
            // track exactly as it was, which is also the thing being judged.
            //
            // Cheap for the same reason it is useful: in trim mode the discarded
            // part is usually just the two ends, and both are downsampled.
            if trimRange != nil {
                ForEach(Array(discardedCoordinates.enumerated()), id: \.offset) { _, piece in
                    MapPolyline(coordinates: piece)
                        .stroke(
                            trimIsRemoval ? Color.red.opacity(0.8) : Color.black.opacity(0.55),
                            // Solid, and narrower than the track it marks.
                            //
                            // The removal overlay used to be dashed `[2, 8]`
                            // at six points wide with round caps, which is not
                            // a dashed line at all — a two-point dash under a
                            // six-point round cap is a six-point dot, so what
                            // it drew was a string of fat beads straddling the
                            // track rather than the track in red. Where the
                            // rider had turned inside one bead's width the
                            // beads merged into a blob, and the shape a rider
                            // was being asked to judge was gone.
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                        )
                }
            }

            if let trimRange {
                if let position = session.track.coordinate(atElapsed: trimRange.lowerBound) {
                    Annotation("", coordinate: position.clCoordinate, anchor: .center) {
                        TrimMarker(isStart: true, isActive: activeTrimEdge == .start)
                    }
                    .annotationTitles(.hidden)
                }
                if let position = session.track.coordinate(atElapsed: trimRange.upperBound) {
                    Annotation("", coordinate: position.clCoordinate, anchor: .center) {
                        TrimMarker(isStart: false, isActive: activeTrimEdge == .end)
                    }
                    .annotationTitles(.hidden)
                }
            }

            if let playhead, let position = session.track.coordinate(atElapsed: playhead) {
                Annotation("", coordinate: position.clCoordinate, anchor: .center) {
                    Playhead(
                        speed: session.track.speed[session.track.index(atElapsed: playhead) ?? 0],
                        maxSpeed: summary.maxSpeed
                    )
                }
                .annotationTitles(.hidden)
            }

            if let start = session.track.points.first?.clCoordinate {
                Marker("Start", systemImage: "flag", coordinate: start)
                    .tint(.green)
            }
            if let end = session.track.points.last?.clCoordinate {
                Marker("End", systemImage: "flag.checkered", coordinate: end)
                    .tint(.red)
            }
        }
        .mapStyle(style.mapStyle)
        .task {
            // Immediately, and once: the outline only depends on the track.
            guard outline.isEmpty else { return }
            let points = session.track.points
            let step = max(1, points.count / 400)
            outline = stride(from: 0, to: points.count, by: step).map {
                points[$0].clCoordinate
            }
        }
        .task(id: bandKey) {
            isDrawing = true
            // Off the main actor: a three-hour track is ten thousand samples,
            // and doing this inline made opening a big session hitch before it
            // ever got near a trim.
            let track = session.track
            let segments = visibleSegments
            let ramp = speedScale
            let dark = style.isDark
            let lastIndex = partialUpTo.flatMap { track.index(atElapsed: $0) }
            let computed = await Task.detached(priority: .userInitiated) {
                Self.makeBands(
                    track: track, segments: segments,
                    scale: ramp, onDark: dark, upTo: lastIndex
                )
            }.value
            guard !Task.isCancelled else { return }
            bands = computed
            if fullTrack.isEmpty { fullTrack = track.points.map(\.clCoordinate) }
            withAnimation(.easeOut(duration: 0.2)) { isDrawing = false }
        }
        // MapKit puts its compass in the top-right the moment the map is
        // rotated and its scale in the top-left when zoomed — both underneath
        // the app's own controls, which live in exactly those corners. The
        // session already shows wind direction on its own dial, so the system
        // pair is redundant here rather than merely inconvenient.
        .mapControls { }
        // Tap the track to jump to that moment.
        //
        // The scrubber under the map answers "what was happening at 14:32",
        // but nobody thinks in elapsed seconds — they think "what was I doing
        // on *that* run", and they are already pointing at it. Taps that land
        // away from the track do nothing rather than seeking to the nearest
        // point on it, because a seek the rider did not ask for looks like a
        // bug and there is no undo for losing your place.
        .onTapGesture { point in
            guard let onSeek,
                  let tapped = proxy.convert(point, from: .local),
                  let hit = nearestSample(to: tapped, tapped: point, proxy: proxy)
            else { return }
            onSeek(hit)
        }
        .onChange(of: isolatedRange) { _, _ in frameSelection() }
        .onAppear { frameSelection() }
    }

    // MARK: - Filtering

    private var visibleSegments: [StateSegment] {
        // Clipped, not merely filtered. A state segment routinely runs across
        // several turns — one unbroken "foiling" stretch can cover half the
        // session — so keeping whole overlapping segments painted four
        // kilometres of track for a 491 m run.
        matchingSegments.map { segment in
            guard let isolatedRange,
                  segment.startIndex < isolatedRange.lowerBound
                    || segment.endIndex > isolatedRange.upperBound
            else { return segment }

            let first = max(segment.startIndex, isolatedRange.lowerBound)
            let last = min(segment.endIndex, isolatedRange.upperBound)
            return StateSegment(
                id: segment.id,
                state: segment.state,
                startIndex: first,
                endIndex: last,
                startElapsed: session.track.elapsed[safe: first] ?? segment.startElapsed,
                endElapsed: session.track.elapsed[safe: last] ?? segment.endElapsed,
                // Distance and speeds are the whole segment's. Nothing on this
                // map reads them — the colour comes from the samples — and
                // recomputing them here would duplicate the analyser to no end.
                distance: segment.distance,
                averageSpeed: segment.averageSpeed,
                maxSpeed: segment.maxSpeed,
                runIndex: segment.runIndex
            )
        }
    }

    private var matchingSegments: [StateSegment] {
        summary.segments.filter { segment in
            if let isolatedRange {
                guard segment.endIndex >= isolatedRange.lowerBound,
                      segment.startIndex <= isolatedRange.upperBound else { return false }
            }
            if foilingOnly, segment.state != .foiling { return false }
            switch foilFilter {
            case .everything: break
            case .foiling: if segment.state != .foiling { return false }
            case .notFoiling: if segment.state == .foiling { return false }
            }
            if let partialUpTo, segment.startElapsed > partialUpTo { return false }
            if minimumSpeed > 0, segment.maxSpeed < minimumSpeed { return false }
            if let highlight {
                let overlaps = segment.startElapsed <= highlight.upperBound
                    && segment.endElapsed >= highlight.lowerBound
                if !overlaps { return false }
            }
            return true
        }
    }

    // MARK: - Speed banding

    /// One stretch of track drawn in a single colour.
    ///
    /// Holds a `Color` rather than an `AnyShapeStyle` so the whole array can be
    /// built off the main actor and handed back.
    struct SpeedBand: Identifiable, Sendable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let colour: Color
        let width: Double
    }

    /// How many steps the ramp is quantised into along the track.
    ///
    /// Enough that acceleration out of a gybe reads as a gradient, few enough
    /// that a three-hour session is a few hundred polylines rather than ten
    /// thousand. MapKit draws each one separately, and that is the cost.
    private static let speedBandCount = 16

    /// The track, split so that colour follows speed *along* it.
    ///
    /// It used to be one polyline per ride-state segment, coloured by that
    /// segment's average — so a foiling run lasting minutes came out one flat
    /// colour. State still controls weight and opacity; only the colour is per
    /// stretch.
    ///
    /// Static and pure so it can run off the main actor. It is also the reason
    /// the trim no longer clips the track: this is expensive, and making it
    /// depend on a value that changes sixty times a second was what made
    /// dragging a handle stutter.
    nonisolated static func makeBands(
        track: Track,
        segments: [StateSegment],
        scale: SpeedScale,
        onDark: Bool,
        upTo lastIndex: Int?
    ) -> [SpeedBand] {
        var bands: [SpeedBand] = []
        var id = 0

        // Colour follows a short rolling mean rather than the raw samples.
        //
        // At one sample a second an unsmoothed ramp flickers between
        // neighbouring bands on GPS noise, which reads as stripes rather than
        // as a gradient — and costs one MapKit overlay per flicker. Five
        // seconds is well below the length of any run, so a real acceleration
        // still shows as one; only the jitter goes.
        let speeds = Self.smoothed(track.speed, window: 5)

        for segment in segments {
            guard segment.startIndex >= 0, segment.endIndex < track.count else { continue }
            // Stop exactly at the playhead rather than a whole segment past it,
            // which is what makes the scrubber reveal the track in order.
            let endIndex = min(segment.endIndex, lastIndex ?? segment.endIndex)
            guard endIndex > segment.startIndex else { continue }
            let coordinates = track.points[segment.startIndex...endIndex].map(\.clCoordinate)
            guard coordinates.count > 1 else { continue }
            let width = lineWidth(for: segment.state)

            // Muted states carry no speed information worth showing — a fall or
            // a drift is about where it happened, not how fast — so they stay a
            // single stroke.
            guard segment.state == .foiling || segment.state == .riding else {
                bands.append(SpeedBand(
                    id: id,
                    coordinates: coordinates,
                    colour: mutedColour(for: segment.state, onDark: onDark),
                    width: width
                ))
                id += 1
                continue
            }

            let start = segment.startIndex
            let dimmed = segment.state == .riding
            var runStart = 0
            var runBand = band(forSpeedAt: start, in: speeds, scale: scale)

            for offset in 1..<coordinates.count {
                let next = band(forSpeedAt: start + offset, in: speeds, scale: scale)
                // A minimum run length, because the cost here is one MapKit
                // overlay per colour change: a noisy stretch flickering between
                // two adjacent bands every sample would otherwise turn a
                // three-hour session into thousands of polylines. Four samples
                // is a few seconds — far below anything the eye reads as a
                // separate colour.
                guard next != runBand, offset - runStart >= 4 else { continue }
                // Overlap by one point so consecutive bands meet rather than
                // leaving a gap the width of the line at every colour change.
                bands.append(SpeedBand(
                    id: id,
                    coordinates: Array(coordinates[runStart...offset]),
                    colour: bandColour(runBand, dimmed: dimmed, midpoint: scale.midpoint),
                    width: width
                ))
                id += 1
                runStart = offset
                runBand = next
            }
            bands.append(SpeedBand(
                id: id,
                coordinates: Array(coordinates[runStart...]),
                colour: bandColour(runBand, dimmed: dimmed, midpoint: scale.midpoint),
                width: width
            ))
            id += 1
        }
        return bands
    }

    /// Centred rolling mean, computed once per rebuild.
    nonisolated private static func smoothed(_ speeds: [Double], window: Int) -> [Double] {
        guard speeds.count > window, window > 1 else { return speeds }
        let half = window / 2
        var prefix: [Double] = [0]
        prefix.reserveCapacity(speeds.count + 1)
        for speed in speeds { prefix.append(prefix[prefix.count - 1] + speed) }

        return speeds.indices.map { i in
            let lower = max(0, i - half)
            let upper = min(speeds.count, i + half + 1)
            return (prefix[upper] - prefix[lower]) / Double(upper - lower)
        }
    }

    nonisolated private static func band(
        forSpeedAt index: Int,
        in speeds: [Double],
        scale: SpeedScale
    ) -> Int {
        guard index >= 0, index < speeds.count else { return 0 }
        return Int(scale.position(of: speeds[index]) * Double(speedBandCount - 1))
    }

    nonisolated private static func bandColour(_ band: Int, dimmed: Bool, midpoint: Double) -> Color {
        let t = Double(band) / Double(speedBandCount - 1)
        let colour = Color(speedRampColour(position: t, midpoint: midpoint))
        return dimmed ? colour.opacity(0.75) : colour
    }

    /// Grey vanishes against imagery, so the muted states lift to white on a
    /// dark base map.
    nonisolated private static func mutedColour(for state: RideState, onDark: Bool) -> Color {
        switch state {
        case .slow: onDark ? .white.opacity(0.6) : .gray.opacity(0.55)
        case .stopped: onDark ? .white.opacity(0.4) : .gray.opacity(0.35)
        case .fall: .red.opacity(0.65)
        default: onDark ? .white.opacity(0.6) : .gray.opacity(0.55)
        }
    }

    /// How wide each state draws.
    ///
    /// Thinner than it was, by about a third. On a session of laps in one
    /// small piece of water — test-5 is two and a quarter hours inside a few
    /// hundred metres — five-point lines merge into a mat where no individual
    /// pass can be picked out, which defeats the reason for drawing the track
    /// rather than a summary. The hierarchy survives the reduction: flying is
    /// still the widest thing on the map.
    ///
    /// Touch is unaffected. A tap is resolved by `nearestSample`, which
    /// searches the track for the closest fix to where the finger landed —
    /// it never hit-tests a stroke, so the target stays exactly as large as
    /// it was.
    nonisolated static func lineWidth(for state: RideState) -> Double {
        switch state {
        case .foiling: 3.2
        case .riding: 2.4
        case .slow: 1.5
        case .stopped: 1.2
        case .fall: 2.2
        }
    }

    /// The stretches the edit would discard.
    ///
    /// The one thing on the map that changes per frame, so it is the one thing
    /// allowed to be recomputed per frame — and it is capped at a few hundred
    /// points per piece, because a marker drawn over an existing line does not
    /// need every sample to look right. Everything else on the map is cached
    /// precisely so that this can be cheap enough to be live.
    private var discardedCoordinates: [[CLLocationCoordinate2D]] {
        guard let trimRange,
              let lower = session.track.index(atElapsed: trimRange.lowerBound),
              let upper = session.track.index(atElapsed: trimRange.upperBound),
              upper > lower, upper < session.track.count else { return [] }

        let ranges: [ClosedRange<Int>] = trimIsRemoval
            ? [lower...upper]
            : [0...lower, upper...(session.track.count - 1)]

        return ranges
            .filter { $0.lowerBound < $0.upperBound }
            .map { range in
                let points = session.track.points[range]
                // A thousand-odd points is nothing for one polyline and it is
                // what keeps the drawn line on the track. Four hundred meant
                // every ninth sample on a long cut, and every ninth sample
                // through a gybe is a chord straight across it.
                let step = max(1, points.count / 1200)
                var result = stride(from: 0, to: points.count, by: step)
                    .map { points[points.startIndex + $0].clCoordinate }
                if let last = points.last { result.append(last.clCoordinate) }
                return result
            }
    }

    /// The elapsed time of the track sample nearest a tap, if the tap was
    /// close enough to count.
    ///
    /// Two passes on purpose. The first finds the nearest sample by real-world
    /// distance, which is cheap and needs no projection. The second measures
    /// how far that sample actually landed from the finger *on screen*, which
    /// is the only threshold that makes sense: 40 metres is a miss when the
    /// whole bay fills the screen and a direct hit when zoomed into one gybe.
    private func nearestSample(
        to coordinate: CLLocationCoordinate2D,
        tapped point: CGPoint,
        proxy: MapProxy
    ) -> TimeInterval? {
        let track = session.track
        guard track.count > 1 else { return nil }
        let target = Geo.Coordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)

        // Stride over a few hundred candidates rather than every fix: at the
        // zoom levels a finger can distinguish, neighbouring samples are the
        // same pixel, and a tap should not walk ten thousand points.
        let step = max(1, track.count / 600)
        var best: (index: Int, distance: Double)?
        for index in stride(from: 0, to: track.count, by: step) {
            let point = track.points[index]
            guard point.hasValidPosition else { continue }
            let distance = Geo.distance(point.coordinate, target)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        guard let best else { return nil }

        // Refine within the stride, so the playhead lands on the sample under
        // the finger rather than up to a few seconds either side of it.
        var refined = best.index
        var refinedDistance = best.distance
        for index in max(0, best.index - step)...min(track.count - 1, best.index + step) {
            let candidate = track.points[index]
            guard candidate.hasValidPosition else { continue }
            let distance = Geo.distance(candidate.coordinate, target)
            if distance < refinedDistance {
                refined = index
                refinedDistance = distance
            }
        }

        guard let onScreen = proxy.convert(track.points[refined].clCoordinate, to: .local) else {
            return nil
        }
        let miss = hypot(onScreen.x - point.x, onScreen.y - point.y)
        // Generous, because a finger is wide and a track drawn at five points
        // is thin — but not so generous that tapping open water seeks.
        guard miss <= 44 else { return nil }
        return track.elapsed[refined]
    }

    /// Where the session's fastest sample happened.
    private var maxSpeedCoordinate: CLLocationCoordinate2D? {
        let speeds = session.track.speed
        guard speeds.count > 1,
              let index = speeds.indices.max(by: { speeds[$0] < speeds[$1] }),
              let point = session.track.points[safe: index],
              point.hasValidPosition else { return nil }
        // Hidden while the track is filtered down to something else, or while a
        // trim is in progress: a peak pinned outside the stretch on screen is
        // just confusing.
        if let partialUpTo, session.track.elapsed[index] > partialUpTo { return nil }
        if trimRange != nil { return nil }
        if foilingOnly || foilFilter != .everything || isolatedRange != nil { return nil }
        return point.clCoordinate
    }

    // MARK: - Camera

    private func frameSelection() {
        let points: [CLLocationCoordinate2D]
        if let isolatedRange {
            let first = max(0, isolatedRange.lowerBound)
            let last = min(session.track.points.count - 1, isolatedRange.upperBound)
            points = first <= last
                ? session.track.points[first...last].map(\.clCoordinate)
                : session.track.points.map(\.clCoordinate)
        } else {
            points = session.track.points.map(\.clCoordinate)
        }
        guard let region = MKCoordinateRegion(fitting: points) else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            camera = .region(region)
        }
    }
}

// MARK: - Markers

/// Where the session's top speed happened, with the number on it.
///
/// Labelled rather than left as another dot: the map already has falls and
/// turns marked, and an unlabelled marker in that company is a puzzle. The
/// point of showing it at all is to connect the headline figure to a place.
struct MaxSpeedMarker: View {
    let speed: Double
    let units: UnitPreferences
    let onDark: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(Format.speed(speed, unit: units.speed, decimals: 1))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            // Static navy, not `.harbourNavy`: the pill sits on map imagery,
            // which never changes with the app's colour scheme.
            .background(Color(red: 0.043, green: 0.290, blue: 0.471), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(onDark ? 0.7 : 0.9), lineWidth: 1.5))

            // A stem, so the capsule points at the sample rather than hovering
            // near it — at this zoom a few points of offset is tens of metres.
            Rectangle()
                .fill(Color(red: 0.043, green: 0.290, blue: 0.471))
                .frame(width: 2, height: 7)
        }
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        .accessibilityLabel("Top speed \(Format.speed(speed, unit: units.speed, decimals: 1))")
    }
}

struct FallMarker: View {
    let fall: Fall

    var body: some View {
        ZStack {
            Circle()
                .fill(.red)
                .frame(width: 14, height: 14)
            Circle()
                .stroke(.white, lineWidth: 2)
                .frame(width: 14, height: 14)
        }
        // A low-confidence detection is drawn faintly rather than asserted.
        .opacity(0.5 + 0.5 * fall.confidence)
    }
}

struct ManeuverMarker: View {
    let maneuver: Maneuver

    var body: some View {
        Circle()
            .fill(maneuver.isDry ? Color.green : Color.orange)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .opacity(0.4 + 0.6 * maneuver.confidence)
    }
}

// MARK: - Bridges

extension Geo.Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension TrackPoint {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MKCoordinateRegion {
    /// A region containing every coordinate, with a little breathing room.
    init?(fitting coordinates: [CLLocationCoordinate2D], padding: Double = 1.35) {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates.dropFirst() {
            minLat = Swift.min(minLat, c.latitude); maxLat = Swift.max(maxLat, c.latitude)
            minLon = Swift.min(minLon, c.longitude); maxLon = Swift.max(maxLon, c.longitude)
        }
        self.init(
            center: CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2,
                longitude: (minLon + maxLon) / 2
            ),
            span: MKCoordinateSpan(
                // A floor stops a single-point or very short track zooming to
                // street level, where it is just a dot.
                latitudeDelta: Swift.max((maxLat - minLat) * padding, 0.002),
                longitudeDelta: Swift.max((maxLon - minLon) * padding, 0.002)
            )
        )
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Map style

/// Which base map to draw under the track.
///
/// Satellite matters more here than in most apps: on open water the standard
/// map is a featureless blue field with nothing to orient by, while imagery
/// shows the shoreline, sandbars and channels that explain why a session went
/// the way it did.
enum MapStyleOption: String, CaseIterable, Identifiable, Sendable {
    case standard
    case hybrid
    case imagery

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Map"
        case .hybrid: "Hybrid"
        case .imagery: "Satellite"
        }
    }

    var symbolName: String {
        switch self {
        case .standard: "map"
        case .hybrid: "globe.americas"
        case .imagery: "globe.americas.fill"
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        case .hybrid: .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        case .imagery: .imagery(elevation: .flat)
        }
    }

    /// Whether the base map is dark, so overlays can pick a readable contrast.
    var isDark: Bool { self != .standard }
}

/// Cycles the base map, styled to sit over either a light or dark one.
struct MapStyleButton: View {
    @Binding var selection: MapStyleOption

    var body: some View {
        Menu {
            Picker("Map style", selection: $selection) {
                ForEach(MapStyleOption.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName).tag(option)
                }
            }
        } label: {
            // The current layer's own symbol rather than a generic stack: the
            // control says what the map is showing as well as what it does, and
            // satellite is worth being able to spot and leave at a glance
            // because it is the one that costs cellular data.
            MapChromeButton { Image(systemName: selection.symbolName) }
        }
        .accessibilityLabel("Map style")
        .accessibilityValue(selection.displayName)
    }
}

/// A circular control that floats on a map.
///
/// Its own view because the size is the point: these were a small glyph with
/// nine points of padding, which lands under Apple's 44-point minimum and made
/// the ••• menu in particular hard to hit — on a boat, with wet hands, over a
/// map that pans if you miss.
struct MapChromeButton<Label: View>: View {
    var action: (() -> Void)?
    @ViewBuilder var label: () -> Label

    var body: some View {
        if let action {
            Button(action: action) { chrome }.buttonStyle(.plain)
        } else {
            chrome
        }
    }

    private var chrome: some View {
        label()
            .font(.subheadline)
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .contentShape(Circle())
    }
}

extension View {
    /// Make map chrome legible over whichever base map is underneath.
    ///
    /// `.regularMaterial` adapts to the *interface* appearance, not to what is
    /// behind it, so in light mode the buttons over satellite imagery came out
    /// pale-on-pale — the controls were there and could not be seen. Forcing
    /// the dark scheme flips every material and label in the overlay in one
    /// move, and the shadow lifts it off imagery that is busy as well as dark.
    func mapChrome(onDark: Bool) -> some View {
        environment(\.colorScheme, onDark ? .dark : .light)
            .shadow(color: .black.opacity(onDark ? 0.45 : 0.12), radius: 5, y: 1)
    }
}

/// The speed colour ramp, explained.
///
/// The track is coloured by speed and nothing on screen said so. A legend is
/// the difference between a pretty gradient and a readable one — and because
/// the ramp is scaled to each session rather than to an absolute range, the
/// end labels carry the actual numbers.
struct SpeedLegend: View {
    /// The same scale the track is drawn with. Passing the session's top speed
    /// and re-deriving the ends here is how the legend and the map came to
    /// disagree about what the colours meant.
    let scale: SpeedScale
    let units: UnitPreferences
    var onDark: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // The bottom of the ramp is a standstill, so it needs no number —
            // and only the top carries a "≥", because that end genuinely
            // clamps while the bottom cannot be passed.
            Text(Format.speed(scale.lower, unit: units.speed, decimals: 0, includeSymbol: false))
            LinearGradient(
                colors: (0...16).map { i in
                    Color(speedRampColour(position: Double(i) / 16, midpoint: scale.midpoint))
                },
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 64, height: 6)
            .clipShape(Capsule())
            Text("≥" + Format.speed(scale.upper, unit: units.speed, decimals: 0))
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(onDark ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
    }
}


/// One end of a trim selection, on the map.
struct TrimMarker: View {

    let isStart: Bool
    let isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isActive ? Color.orange : Color.yellow)
                .frame(width: isActive ? 30 : 22, height: isActive ? 30 : 22)
                .overlay {
                    Circle().stroke(.white, lineWidth: 2.5)
                }
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)

            Image(systemName: isStart ? "chevron.right" : "chevron.left")
                .font(.system(size: isActive ? 14 : 11, weight: .black))
                .foregroundStyle(.black.opacity(0.65))
        }
        // The end being dragged grows, so the eye can find it without hunting
        // through the other forty passes crossing the same water.
        .animation(.snappy(duration: 0.15), value: isActive)
        .accessibilityLabel(isStart ? "Trim start" : "Trim end")
    }
}
