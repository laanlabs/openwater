import MapKit
import OpenWaterCore
import SwiftUI

/// The flow map's colour wash, on the main Spots map — as map content,
/// not a picture over it.
///
/// The flow map paints a geo-registered raster, which SwiftUI's `Map`
/// cannot draw; the honest translation is cells: the same 7×9 model grid,
/// bilinearly upsampled the way the raster upsamples, stepped through the
/// same `WindPalette` bands, emitted as a few hundred `MapPolygon`s. Being
/// map *content* is the point — MapKit keeps them under every pin and
/// annotation, carries them through pan, zoom and rotation for free, and
/// nothing recomputes per frame: the cells change only when the field
/// refetches, which is the pins-as-state discipline applied to weather.
/// The cells' colours are lerped through the palettes' band midpoints
/// rather than stepped, so neighbouring cells differ by a breath and the
/// field reads as one gradient — the reference apps' surface, built from
/// quads.
/// What the map's wash is showing, if anything. A picker, not a stack —
/// two translucent fields over one another would say nothing about either.
enum WashLayer: String, CaseIterable {
    case off, wind, currents

    /// The caption's front half; the view appends the clock — "now", or
    /// the scrubbed hour while a slider owns the map. The wind half names
    /// whichever model the rider picked, because a caption that says
    /// "Open-Meteo model" over GFS's numbers is a label on the wrong tin;
    /// the current wash keeps the ocean model, which the picker does not
    /// govern — the marine API runs its own.
    var caption: String? {
        switch self {
        case .off: nil
        case .wind: "Wind wash · \(ForecastModel.selected.captionName)"
        case .currents: "Current wash · Open-Meteo ocean model"
        }
    }
}

@MainActor
@Observable
final class WindWashModel {

    /// One cell of the field: a quad and the band its value falls in.
    struct Cell: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    /// The live field the particles stream through: the raw grids the
    /// cells were coloured from, kept so the animation samples the same
    /// bilinear surface. Directions are resolved at build time — wind
    /// flipped downwind (the streamline convention), currents as-is
    /// because they already state *toward* — so the sim advects blindly.
    struct Field {
        /// Stamped per *fetch*, not per rebuild: scrubbing hours keeps the
        /// stamp, so the comet sim keeps its particles and only the wind
        /// under them changes.
        let id: UUID
        /// Which fluid this is. Air and water differ by an order of
        /// magnitude — eighteen knots is an ordinary afternoon, one and a
        /// half is a strong tide — so they cannot share a pace.
        let flow: Flow
        /// Where the land is, so a comet cannot stream up a street. Empty
        /// for wind, which has every right to blow over a hill.
        let mask: WaterMask
        let region: MKCoordinateRegion
        let columns: Int
        let rows: Int
        /// Speed-weighted components per node — u east, v north, the way
        /// the fluid runs — nil where the model is silent.
        let vectors: [(u: Double, v: Double)?]

        /// Bilinear sample at fractional grid coordinates; components are
        /// interpolated rather than angles, which would spin the long way
        /// round across north.
        func vector(gx: Double, gy: Double) -> (u: Double, v: Double)? {
            let column0 = max(0, min(Int(gx), columns - 2))
            let row0 = max(0, min(Int(gy), rows - 2))
            let tx = gx - Double(column0), ty = gy - Double(row0)
            let corners = [
                (vectors[row0 * columns + column0], (1 - tx) * (1 - ty)),
                (vectors[row0 * columns + column0 + 1], tx * (1 - ty)),
                (vectors[(row0 + 1) * columns + column0], (1 - tx) * ty),
                (vectors[(row0 + 1) * columns + column0 + 1], tx * ty),
            ]
            // The same rule the cells are built by — nearest node vetoes,
            // live corners shade — so a comet never streams over water the
            // wash has decided is land, or stops where it has not.
            guard let nearest = corners.max(by: { $0.1 < $1.1 }), nearest.0 != nil
            else { return nil }
            // The DEM has the last word: the model will happily answer with
            // the nearest sea cell's water for a point three kilometres
            // inland, and a comet crossing the Financial District is the
            // most visible way to say something is wrong.
            if mask.isWater(coordinate(gx: gx, gy: gy)) == false { return nil }
            var u = 0.0, v = 0.0, weight = 0.0
            for (value, w) in corners {
                guard let value else { continue }
                u += value.u * w
                v += value.v * w
                weight += w
            }
            guard weight > 0.25 else { return nil }
            return (u: u / weight, v: v / weight)
        }

        func coordinate(gx: Double, gy: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: region.center.latitude - region.span.latitudeDelta / 2
                    + region.span.latitudeDelta * gy / Double(rows - 1),
                longitude: region.center.longitude - region.span.longitudeDelta / 2
                    + region.span.longitudeDelta * gx / Double(columns - 1))
        }

        /// The inverse of `coordinate(gx:gy:)` — pins the sim to whatever
        /// slice of the field the camera is actually looking at.
        func grid(of coordinate: CLLocationCoordinate2D) -> (gx: Double, gy: Double) {
            let south = region.center.latitude - region.span.latitudeDelta / 2
            let west = region.center.longitude - region.span.longitudeDelta / 2
            return ((coordinate.longitude - west) / region.span.longitudeDelta * Double(columns - 1),
                    (coordinate.latitude - south) / region.span.latitudeDelta * Double(rows - 1))
        }
    }

    /// What the comets are streaming through, and how fast that reads.
    ///
    /// The pace is absolute *within* a fluid — half the speed is half the
    /// pace, which is what makes a glance at the flow a reading of it — but
    /// the reference differs between them, because the fluids do. Paced by
    /// the wind's numbers, a one-knot ebb crossed the screen in about four
    /// minutes: a field that reads as still, over water that is moving hard
    /// enough to decide whether a rider gets home.
    enum Flow {
        case wind, current

        /// The speed that crosses the visible span in `crossSeconds`.
        var referenceKn: Double {
            switch self {
            case .wind: 18
            case .current: 1.2
            }
        }

        var crossSeconds: Double {
            switch self {
            case .wind: 6
            case .current: 5
            }
        }

        /// The speeds between which the tail grows from a stub to a streak.
        var tailRamp: (from: Double, to: Double) {
            switch self {
            case .wind: (3, 25)
            case .current: (0.1, 2.2)
            }
        }

        /// Below this there is nothing honest to draw — dead calm, or slack
        /// water.
        var stillKn: Double {
            switch self {
            case .wind: 0.05
            case .current: 0.015
            }
        }
    }

    /// The half of a cell the clock cannot change: where the quad is, and
    /// how far into the field's own feathered edge it sits.
    ///
    /// Split out because the expensive half of building a field is the
    /// geometry — four coordinates and a coastline lookup per quad,
    /// seventeen hundred quads — and none of it moves when the hour does.
    /// Built once per field rectangle, then every scrubbed hour is a
    /// bilinear sample and a colour lerp over a table that already exists:
    /// a few thousand multiplies, on a thread that is not the map's.
    struct CellLayout {
        let id: Int
        /// Fractional model-grid coordinates of the quad's centre, so the
        /// hour's speeds can be sampled without re-deriving them.
        let gx: Double
        let gy: Double
        let coordinates: [CLLocationCoordinate2D]
        /// The edge feather, already worked out from the cell's ring.
        let ringAlpha: Double
    }

    private(set) var cells: [Cell] = []
    private(set) var field: Field?
    private(set) var fieldRegion: MKCoordinateRegion?
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var loadedLayer: WashLayer = .off

    /// The slice of the field the layout was actually built for.
    ///
    /// The field is fetched wide on purpose — one request buys 45 km, and
    /// panning inside it costs nothing. Drawing it wide is a different
    /// matter: at the zoom a rider reads a launch at, a 3 km view sits
    /// inside a 45 km field, so under one per cent of the quads are on
    /// screen and the other ninety-nine are a second of main thread spent
    /// on geometry nobody can see. So the fetch stays wide and the drawing
    /// is cut to a window around the view, generous enough that an ordinary
    /// pan stays inside it.
    @ObservationIgnored private var drawWindow: MKCoordinateRegion?

    /// How much wider than the view the drawn window is. Big enough that
    /// panning a screen's width does not need a redraw, small enough that
    /// the redraw it eventually needs is cheap.
    nonisolated private static let drawPadding = 2.4

    /// The visible region the loaded field was sized for — the yardstick
    /// `needsReload` measures a zoom change against.
    @ObservationIgnored private var loadedVisible: MKCoordinateRegion?

    /// How many degrees of longitude one device pixel covered at the zoom
    /// the field was last loaded for. Nil until a load has happened.
    ///
    /// This is the whole input to the seam inset — see `buildLayout`. It is
    /// a snapshot, and the camera can drift by up to the reload threshold
    /// before a fresh one is taken, so the inset is right to within a factor
    /// of about two. That is fine: the failure at either end is a fraction
    /// of a pixel of overlap or of gap, against the two whole pixels of
    /// overlap it is cancelling.
    @ObservationIgnored private var degreesPerPixel: Double?

    /// The current field's geometry, kept across hours. Dropped whenever
    /// the rectangle or the land mask changes — the only two things that
    /// can move a quad.
    ///
    /// The rebuild's bookkeeping is all `@ObservationIgnored`: none of it is
    /// anything a view has a reason to redraw for, and the wash publishes
    /// through `cells` and `field` alone.
    @ObservationIgnored private var layout: [CellLayout]?
    /// The hour a rebuild has been asked for but not yet started. One slot,
    /// not a queue: a thumb sweeping three days puts a hundred hours
    /// through here and only the last one is worth drawing.
    @ObservationIgnored private var pendingIndex: Int?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    /// Bumped whenever the field underneath a running rebuild is replaced,
    /// so a worker that is mid-flight when the map moves retires quietly
    /// instead of publishing cells for a rectangle that is gone.
    @ObservationIgnored private var rebuildToken = 0
    /// The floor between two published fields.
    ///
    /// Colouring the cells is cheap and off the main actor now — about
    /// thirty milliseconds, and none of them the map's. Handing MapKit the
    /// finished quads is neither: overlay updates are the main thread's by
    /// definition, and seventeen hundred of them measured around 400 ms on
    /// a simulator. Nothing can make that concurrent, so the only lever is
    /// how often it happens, and this is the floor under it — for the paths
    /// that book hours continuously rather than one settled hour at a time.
    private static let rebuildInterval = Duration.milliseconds(120)
    nonisolated private static let clock = ContinuousClock()
    /// When the last field reached the map, for the throttle to measure
    /// from. Nil means nothing has been published since the field landed,
    /// so the first one never waits.
    @ObservationIgnored private var lastPublish: ContinuousClock.Instant?

    /// The day the wash was fetched with, kept whole so a route's slider
    /// can scrub the field through its hours without touching the network.
    private var hourAxis: [Date] = []
    private var hourly: [(speeds: [Double?], directions: [Double?])] = []
    /// The instant a route's slider is holding, nil for "now".
    private var scrubbedTo: Date?
    /// Which axis hour has been *asked* for — the no-op guard that keeps
    /// fifteen-second scrub ticks from rebuilding anything until the thumb
    /// actually crosses an hour.
    private var bookedIndex: Int?
    /// Which axis hour the cells on screen are actually showing. Behind
    /// `bookedIndex` while a rebuild is in flight, and the one the caption
    /// reads — the wash's clock has to name the field the rider can see,
    /// not the one being built for them.
    private var displayedIndex: Int?
    /// Whether a rebuild is being held back for a moving thumb.
    ///
    /// Bookings still land during a drag; nothing is built until the thumb
    /// pauses or lifts. Handing MapKit seventeen hundred fresh polygons
    /// costs about half a second of main thread, and no thread can be
    /// borrowed for it — overlay updates are the main thread's by
    /// definition. Several of those a second is the lockup, so the field
    /// waits for the rider to stop somewhere before it redraws.
    private var isScrubbing = false
    /// Whether the gesture itself is still going, which is what re-arms
    /// the pause timer. Kept apart from `isScrubbing` because a pause
    /// clears the hold without ending the drag.
    @ObservationIgnored private var thumbIsDown = false
    @ObservationIgnored private var scrubSettle: Task<Void, Never>?
    /// True between the camera starting to move and settling. Repainting
    /// costs the main thread about a second, and spending it in the middle
    /// of somebody's pan is the whole complaint — so the field waits for the
    /// map to stop, the same bargain the slider makes.
    private var cameraIsMoving = false

    /// Whether the rider is owed a field they cannot see yet — fetching, or
    /// rebuilding, or holding a rebuilt one back for a moving map. The view
    /// puts a quiet progress hud up on this.
    var isBusy: Bool { isLoading || isRebuilding }
    /// How still a thumb has to be before the field catches up under it.
    /// Short enough to feel like an answer, long enough that a sweep
    /// across three days never triggers one.
    private static let scrubPause = Duration.milliseconds(350)
    /// An hour has been asked for that the map is not showing yet.
    private(set) var isRebuilding = false
    private var fieldStamp = UUID()
    /// Where the land is, for the layer that must not paint over it.
    ///
    /// Rasterized from the bundled coastline for exactly the field's own
    /// rectangle, so every cell the wash draws is inside it — there is no
    /// half-loaded state to wait out and no coarser answer for a wider view.
    private var waterMask = WaterMask()
    private var maskTask: Task<Void, Never>?

    private static let hourLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The weekday joins the clock once the hour leaves today — a route
    /// planned for Thursday must not wear a caption that reads as now.
    private static let dayHourLabel: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    /// What the caption's clock should read; nil means "now".
    var scrubLabel: String? {
        guard scrubbedTo != nil, let displayedIndex,
              hourAxis.indices.contains(displayedIndex) else { return nil }
        let hour = hourAxis[displayedIndex]
        let formatter = Calendar.current.isDateInToday(hour) ? Self.hourLabel : Self.dayHourLabel
        return formatter.string(from: hour)
    }

    /// Point the wash at an instant (a route slider's), or back at now.
    /// Pure re-render from the stored day — never a fetch.
    func scrub(to instant: Date?) {
        scrubbedTo = instant
        guard loadedLayer != .off else { return }
        apply()
    }

    /// Ask for the hour nearest the scrubbed instant. The field keeps its
    /// stamp across hours so the comets ride the change instead of reseeding.
    ///
    /// This only *books* the work. The cells themselves are built off the
    /// main actor by `drainRebuilds()`, and the booking is a single slot —
    /// a thumb crossing an hour every few milliseconds leaves one hour
    /// waiting, never a backlog to grind through after the finger lifts.
    ///
    /// `force` is for a mask landing: the hour has not changed, but what
    /// counts as water has, so the no-op guard has to be stepped past and
    /// the geometry redrawn.
    private func apply(force: Bool = false) {
        guard fieldRegion != nil, !hourAxis.isEmpty else { return }
        let target = scrubbedTo ?? Date()
        let index = hourAxis.indices.min {
            abs(hourAxis[$0].timeIntervalSince(target)) < abs(hourAxis[$1].timeIntervalSince(target))
        } ?? 0
        guard force || index != bookedIndex, hourly.indices.contains(index) else { return }
        // Claimed here rather than when the rebuild lands, so the fifteen-
        // second scrub ticks the route panel runs on keep no-opping while
        // the hour they asked for is still in the oven.
        bookedIndex = index
        if force { layout = nil }
        pendingIndex = index
        isRebuilding = true
        if thumbIsDown {
            isScrubbing = true
            armScrubPause()
        }
        drainRebuilds()
    }

    /// A finger took hold of a time slider, and let go of it.
    ///
    /// The wash holds still in between — except where the thumb stops
    /// moving, which is a rider arriving somewhere rather than passing
    /// through, and is worth a field. Rebuilding on every hour a sweep
    /// crosses costs half a second of blocked main thread apiece, and none
    /// of those intermediate fields is one anybody asked to look at.
    ///
    /// The map's own clock does not call this: it keeps the drag inside
    /// `MapClock` and only reports the hours it settles on, which is the
    /// same bargain made one level up. This is for the route panel's run
    /// slider, whose thumb genuinely does drive the map continuously.
    func beginScrub() {
        thumbIsDown = true
        isScrubbing = true
        armScrubPause()
    }

    /// The map's camera started moving, and stopped.
    func cameraMoving() {
        cameraIsMoving = true
    }

    func cameraSettled() {
        cameraIsMoving = false
        drainRebuilds()
    }

    func endScrub() {
        thumbIsDown = false
        scrubSettle?.cancel()
        scrubSettle = nil
        isScrubbing = false
        drainRebuilds()
    }

    /// Catch the field up if the thumb goes still. Doubles as the safety
    /// net: a slider that never reports the lift — and SwiftUI's does drop
    /// one now and then — must not be able to freeze the wash forever.
    private func armScrubPause() {
        scrubSettle?.cancel()
        scrubSettle = Task {
            try? await Task.sleep(for: Self.scrubPause)
            guard !Task.isCancelled, isScrubbing else { return }
            isScrubbing = false
            drainRebuilds()
        }
    }

    /// The worker: takes whatever hour is waiting, colours it away from the
    /// main actor, publishes, and goes round again if the thumb moved on.
    ///
    /// One worker at a time. Everything here is `@MainActor`, so the reads
    /// and writes of `pendingIndex` cannot interleave with `apply()`; the
    /// only suspension points are the detached build and the throttle, and
    /// both are guarded by the token on the way back.
    private func drainRebuilds() {
        guard !isScrubbing, !cameraIsMoving, rebuildTask == nil else { return }
        rebuildToken += 1
        let token = rebuildToken
        rebuildTask = Task {
            while !Task.isCancelled, rebuildToken == token, !isScrubbing, !cameraIsMoving,
                  pendingIndex != nil {
                // The throttle is a clock, not a queue check. Publishing
                // blocks the main thread long enough that the slider's next
                // step has not been delivered yet when the worker looks —
                // so "is anything waiting?" always answered no, the worker
                // retired, and the queued step started a fresh one with no
                // wait at all. Timing the gap between *publishes* is the
                // only version that actually holds the pace.
                if let lastPublish {
                    let waited = Self.clock.now - lastPublish
                    if waited < Self.rebuildInterval {
                        try? await Task.sleep(for: Self.rebuildInterval - waited)
                        guard !Task.isCancelled, rebuildToken == token else { return }
                    }
                }
                // Read *after* the wait: whatever the thumb reached while
                // this worker was asleep is the hour worth drawing, and
                // every hour it swept past on the way is not.
                guard let index = pendingIndex else { break }
                pendingIndex = nil
                guard let region = fieldRegion, hourly.indices.contains(index) else { break }
                let layer = loadedLayer
                let hour = hourly[index]
                // The mask is the current layer's business only — wind blows
                // over land, and a wind wash that stopped at the shoreline
                // would hide the very thing a rider on a beach is asking
                // about.
                let mask = layer == .currents && Self.masksLand ? waterMask : WaterMask()
                let known = layout
                // Half a device pixel per side, which is the whole pixel
                // MapKit bleeds across a shared edge. Measured: a full pixel
                // each side overshoots into a visible dark gap, half lands
                // on the field's own brightness. Nothing known about the
                // zoom yet means no correction rather than a guessed one.
                let inset = (degreesPerPixel ?? 0) * Self.seamPixels
                let window = drawWindow

                // `nonisolated` is not enough to leave the main actor under
                // approachable concurrency — a nonisolated call from here
                // runs here. Detached is the honest way to say "another
                // thread", and it is the same handover `loadMask` uses.
                let built = await Task.detached(priority: .userInitiated) {
                    let table = known ?? Self.buildLayout(region: region, mask: mask,
                                                          insetLon: inset, window: window)
                    return (table, Self.colourCells(table, speeds: hour.speeds, layer: layer))
                }.value

                guard !Task.isCancelled, rebuildToken == token else { return }
                layout = built.0
                cells = built.1
                field = Field(
                    id: fieldStamp,
                    flow: layer == .currents ? .current : .wind,
                    mask: mask,
                    region: region,
                    columns: FlowMapScreen.columns, rows: FlowMapScreen.rows,
                    vectors: zip(hour.speeds, hour.directions).map { speed, direction in
                        guard let speed, let direction else { return nil }
                        let runs = (layer == .wind ? direction + 180 : direction) * .pi / 180
                        return (u: speed * sin(runs), v: speed * cos(runs))
                    })

                displayedIndex = index
                lastPublish = Self.clock.now
            }
            if rebuildToken == token {
                rebuildTask = nil
                isRebuilding = pendingIndex != nil
            }
        }
    }

    /// Retire the running rebuild and forget what it was working towards —
    /// for whenever the field under it is being replaced.
    private func cancelRebuild() {
        rebuildToken += 1
        rebuildTask?.cancel()
        rebuildTask = nil
        pendingIndex = nil
        isRebuilding = false
        // A new field is not a scrub: it should paint the moment it lands,
        // without serving out the throttle the old one was under.
        lastPublish = nil
    }

    /// How much finer the cells are than the model grid — the floor, and
    /// what the whole field is drawn at when the view is as wide as it.
    ///
    /// Three left a 45 km field in cells about two and a half kilometres
    /// across, which at the zoom a rider actually reads a launch at is a
    /// quad the size of a thumbnail — the field stopped looking like water
    /// and started looking like a spreadsheet. Six halves that again in
    /// both directions, which MapKit composites without complaint, and the
    /// gradient between the model's own nodes finally reads as a gradient.
    /// It adds no information — the model has what it has — but a smooth
    /// surface is the honest picture of a field that genuinely is smooth,
    /// where hard squares imply edges the water does not have.
    nonisolated private static let minUpsample = 6

    /// How many quads the drawn window may hold.
    ///
    /// The one real cost in this file. Handing MapKit a polygon costs the
    /// main thread about six tenths of a millisecond and no other thread
    /// may do it, so this number *is* the hitch when the hour changes:
    /// four hundred is a couple of frames, seventeen hundred was a second.
    nonisolated private static let drawBudget = 420

    /// How fine to cut the field for the window being drawn.
    ///
    /// Six was a constant, and a constant is only right at one zoom. It was
    /// chosen for a view as wide as the field; but the field has a 45 km
    /// floor, so a rider zoomed in on their launch was looking at two of
    /// those quads with a seam between them — a flat sheet with a line
    /// across it, which is not what a wind field looks like. The model has
    /// nothing more to say at that scale, and this does not pretend it
    /// does; it just stops the interpolation it is already doing from being
    /// drawn in slabs.
    ///
    /// The window is what makes this affordable. Cutting finer multiplies
    /// the quads over the whole field, but only the ones in the window are
    /// ever built, so the count that reaches MapKit stays near the budget
    /// at every zoom.
    nonisolated private static func drawUpsample(field: MKCoordinateRegion,
                                                 window: MKCoordinateRegion?) -> Int {
        guard let window else { return minUpsample }
        let share = min(1, window.span.latitudeDelta / field.span.latitudeDelta)
            * min(1, window.span.longitudeDelta / field.span.longitudeDelta)
        guard share > 0 else { return minUpsample }
        // total ≈ columns² · (rows−1)/(columns−1) · share, in cells across
        // the *field*; solve that for the cells-across that spends the
        // budget on the window.
        let aspect = Double(FlowMapScreen.rows - 1) / Double(FlowMapScreen.columns - 1)
        let across = (Double(drawBudget) / (aspect * share)).squareRoot()
        let steps = Int((across / Double(FlowMapScreen.columns - 1)).rounded(.down))
        return max(minUpsample, min(steps, 512))
    }
    /// The wash's strength. The balance that took three tries: heavy
    /// enough that the field's colours read as a surface, light enough
    /// that the muted map's coastline still shows through — you can see
    /// the wind *and* where the wind is. The basemap goes muted while a
    /// wash is up (SpotsTabView), so the wash owns all the colour; the
    /// outer rings fade so the field ends in a feather, not a wall.
    nonisolated private static let washAlpha = 0.5
    /// Device pixels of overlap to pull out of each side of a quad.
    ///
    /// Measured, not derived. Against a field reading 138 on a 3× simulator,
    /// a seam ran +73 with the old stroke, +31 with no correction at all,
    /// +12 at half a pixel and −27 at a whole one; it crosses around six
    /// tenths, and past that it opens a dark gap instead.
    ///
    /// It cannot be nulled everywhere at once — each seam falls differently
    /// across the pixel grid, and repeat runs of the same measurement move
    /// by a few counts — so what is left is under a tenth of the field's own
    /// brightness either way, against the half the stroke was adding. The
    /// unit is device pixels precisely so this holds at every zoom.
    nonisolated private static let seamPixels = 0.6

    // MARK: The gradient

    /// The Orca look is a gradient, not bands: colour lerped between the
    /// palettes' own band midpoints, so every cell wears its own shade and
    /// the field reads as one continuous surface. The palettes remain the
    /// single source of the colours — this only smooths between them.
    nonisolated private static func smoothColour(for knots: Double, layer: WashLayer) -> Color {
        // Wind reads its own palette's continuous form — the conditions
        // strip reads the same one, which is why it lives on the palette
        // rather than here.
        guard layer == .currents else { return Color(uiColor: WindPalette.smooth(for: knots)) }
        let stops = currentStops
        guard let first = stops.first, let last = stops.last else { return .clear }
        if knots <= first.at { return Color(uiColor: first.colour) }
        if knots >= last.at { return Color(uiColor: last.colour) }
        for index in 1..<stops.count where knots < stops[index].at {
            let a = stops[index - 1], b = stops[index]
            return Color(uiColor: WindPalette.lerp(a.colour, b.colour,
                                                   (knots - a.at) / (b.at - a.at)))
        }
        return Color(uiColor: last.colour)
    }

    /// The current palette's band midpoints, sampled through the palette
    /// itself so the two can never drift apart.
    nonisolated private static let currentStops: [(at: Double, colour: UIColor)] =
        [0.1, 0.35, 0.65, 1.0, 1.4, 1.9, 2.6].map {
            ($0, UIColor(CurrentPalette.color(for: $0)))
        }

    /// The land-mask switch moved: rebuild what is on screen with the new
    /// answer, rasterizing the coastline if it just came on.
    func maskPreferenceChanged(for visible: MKCoordinateRegion, layer: WashLayer) {
        guard layer == .currents else { return }
        if Self.masksLand { loadMask() } else { apply(force: true) }
    }

    /// Tell the wash how big the map is drawn, so the cell builder can size
    /// its seam inset in real pixels. Cheap and idempotent; the view calls
    /// it whenever the map's frame changes.
    func mapMeasured(widthPoints: CGFloat, displayScale: CGFloat, visible: MKCoordinateRegion) {
        guard widthPoints > 0, displayScale > 0 else { return }
        degreesPerPixel = visible.span.longitudeDelta / (Double(widthPoints) * Double(displayScale))
    }

    /// The map settled somewhere — refetch if it wandered far enough from
    /// the loaded field, or if the rider switched what the field shows.
    /// Thresholds are the flow map's own.
    /// Whether the current wash is cut to the coastline.
    ///
    /// Still a switch, though the coastline no longer depends on a network
    /// that can refuse it. Natural Earth's 1:10m shoreline is a generalisation,
    /// and where it is simply wrong about a stretch of water — a dredged
    /// channel, a new breakwater, an island below its resolution — a rider
    /// should be able to turn it off and get the field back rather than stare
    /// at a hole where their launch is.
    ///
    /// The default lives here *and* in `SpotsTabView`, because this is read
    /// from a model with no view around it. Both say on; they have to.
    static var masksLand: Bool {
        UserDefaults.standard.object(forKey: "spots.maskLand") as? Bool ?? true
    }

    func viewSettled(on visible: MKCoordinateRegion, layer: WashLayer,
                     widthPoints: CGFloat, displayScale: CGFloat) {
        mapMeasured(widthPoints: widthPoints, displayScale: displayScale, visible: visible)
        guard layer != .off else { return clear() }
        if layer != loadedLayer || needsReload(for: visible) {
            return reload(for: visible, layer: layer)
        }
        // The data still covers this view; only the drawn slice of it may
        // have to move, and that is arithmetic rather than a round trip.
        guard needsRecull(for: visible) else { return }
        drawWindow = Self.paddedWindow(for: visible)
        apply(force: true)
    }

    /// The window the quads are drawn for: the view, opened out.
    nonisolated private static func paddedWindow(for visible: MKCoordinateRegion) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: visible.center,
            span: MKCoordinateSpan(latitudeDelta: visible.span.latitudeDelta * drawPadding,
                                   longitudeDelta: visible.span.longitudeDelta * drawPadding))
    }

    /// Whether the view has moved far enough that the drawn slice no longer
    /// comfortably covers it. Cheaper than `needsReload` by a network round
    /// trip, so it can afford to be stricter.
    private func needsRecull(for visible: MKCoordinateRegion) -> Bool {
        guard let window = drawWindow else { return true }
        let zoom = visible.span.latitudeDelta / (window.span.latitudeDelta / Self.drawPadding)
        if zoom > 1.35 || zoom < 0.7 { return true }
        let marginLat = (window.span.latitudeDelta - visible.span.latitudeDelta) / 2
        let marginLon = (window.span.longitudeDelta - visible.span.longitudeDelta) / 2
        return abs(visible.center.latitude - window.center.latitude) > marginLat * 0.75
            || abs(visible.center.longitude - window.center.longitude) > marginLon * 0.75
    }

    /// Draw the coastline for the field's own rectangle.
    ///
    /// Off the main actor because rasterizing a continent is tens of
    /// milliseconds of path filling, and the map is being panned while it
    /// happens. The wash paints unmasked until this lands and switches over in
    /// one go — the same handover the tiled version needed, now measured in a
    /// frame or two rather than a rider's patience.
    private func loadMask() {
        guard let region = fieldRegion else { return }
        maskTask?.cancel()
        maskTask = Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                Coastline.mask(for: region)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.waterMask = drawn
            // The hour has not moved, only what counts as water — so this
            // rebuild has to be forced past the no-op guard.
            self.apply(force: true)
        }
    }

    func clear() {
        loadTask?.cancel()
        loadTask = nil
        maskTask?.cancel()
        maskTask = nil
        scrubSettle?.cancel()
        scrubSettle = nil
        isScrubbing = false
        cancelRebuild()
        cells = []
        field = nil
        fieldRegion = nil
        loadedVisible = nil
        drawWindow = nil
        layout = nil
        hourAxis = []
        hourly = []
        bookedIndex = nil
        displayedIndex = nil
        loadedLayer = .off
        isLoading = false
    }

    /// Whether the view has left what was fetched for it.
    ///
    /// This was the flow map's drift rule, verbatim, and on this map it was
    /// wrong in a way that cost a network round trip and a repaint on *every
    /// pan*. That rule compares the view against the field, which works on
    /// the flow map because the field there is the view. Here the field is
    /// the view widened and then clamped to a 45 km floor — so at any zoom
    /// closer than about eighty kilometres the view is a small fraction of
    /// the field by construction, `spanRatio < 0.55` is permanently true,
    /// and the map refetched every time the camera stopped. Measured: a fetch
    /// and a 1.3 s repaint after each pan, over data that already covered
    /// where the rider had panned to.
    ///
    /// So the two questions are asked separately. Zoom is measured against
    /// the *view* the field was sized for, because that is what set the cell
    /// size. Drift is measured against the field's own edge, because a pan
    /// inside a rectangle that has already been fetched needs nothing at all.
    private func needsReload(for visible: MKCoordinateRegion) -> Bool {
        guard let field = fieldRegion, let loaded = loadedVisible else { return true }
        let zoom = visible.span.latitudeDelta / loaded.span.latitudeDelta
        if zoom > 1.6 || zoom < 0.6 { return true }
        // How far the centre may wander before the view starts running off
        // the fetched rectangle. The floor keeps this sane at the widest
        // zooms, where the clamp can leave the field no bigger than the view.
        let marginLat = max((field.span.latitudeDelta - visible.span.latitudeDelta) / 2,
                            visible.span.latitudeDelta * 0.25)
        let marginLon = max((field.span.longitudeDelta - visible.span.longitudeDelta) / 2,
                            visible.span.longitudeDelta * 0.25)
        return abs(visible.center.latitude - field.center.latitude) > marginLat * 0.6
            || abs(visible.center.longitude - field.center.longitude) > marginLon * 0.6
    }

    /// The flow map's field sizing, verbatim.
    private func clampedField(for visible: MKCoordinateRegion) -> MKCoordinateRegion {
        var region = visible
        region.span.latitudeDelta *= 1.2
        region.span.longitudeDelta *= 1.2
        let latMetres = region.span.latitudeDelta * 110_574
        let clamped = min(max(latMetres, 45_000), 2_500_000)
        let scale = clamped / latMetres
        region.span.latitudeDelta = min(region.span.latitudeDelta * scale, 120)
        region.span.longitudeDelta = min(region.span.longitudeDelta * scale, 340)
        return region
    }

    private func reload(for visible: MKCoordinateRegion, layer: WashLayer) {
        let target = clampedField(for: visible)
        loadTask?.cancel()
        // Let the old field go before the new one is asked for. It was drawn
        // for a rectangle the rider has left, and — more to the point —
        // seventeen hundred polygons on the map is what makes the map
        // expensive to move. Dropping them here is what keeps panning free
        // while the fetch is in the air; the hud says why the water is bare.
        cancelRebuild()
        cells = []
        field = nil
        layout = nil
        loadTask = Task {
            isLoading = true
            let coords = gridCoordinates(for: target)
            let count = FlowMapScreen.columns * FlowMapScreen.rows
            // Three days deep and six hours behind, rather than one
            // hour: the map's time slider and the route panel's both
            // scrub the wash through these rows, and the depth costs the
            // same one request either way. Unscrubbed, the shown hour is
            // simply the one nearest now.
            var axis: [Date] = []
            var day: [(speeds: [Double?], directions: [Double?])] = []
            switch layer {
            case .wind:
                let field = await OpenMeteo.windAlong(
                    coords, hours: SpotGuideStore.scrubForecastHours,
                    pastHours: SpotGuideStore.scrubPastHours)
                guard !Task.isCancelled else { return }
                // Laying the answer onto a shared axis is ~4,500 rows of
                // pure arithmetic over values, and it lands mid-pan — so it
                // goes to another thread rather than into the frame the map
                // was about to draw.
                (axis, day) = await Task.detached(priority: .userInitiated) {
                    let axis = (field.max { $0.count < $1.count })?.map(\.date) ?? []
                    // A hash of the axis, not a linear search per row: three
                    // days across sixty-three points is ~4,500 rows, and
                    // `firstIndex(of:)` would walk seventy-two dates for each
                    // of them — a third of a million comparisons where a
                    // dictionary costs one.
                    let slots = Self.slotIndex(of: axis)
                    var day = Self.blankDay(hours: axis.count, points: count)
                    for (coordIndex, rows) in field.enumerated() where coordIndex < count {
                        for row in rows {
                            guard let slot = slots[row.date] else { continue }
                            day[slot].speeds[coordIndex] = row.speedKn
                            day[slot].directions[coordIndex] = row.directionDeg
                        }
                    }
                    return (axis, day)
                }.value
            case .currents:
                // The ocean model answers nil over land, so the current
                // wash paints only the water — the field's own honesty,
                // no land mask needed.
                let field = await OpenMeteo.marineAlong(
                    coords, hours: SpotGuideStore.scrubForecastHours,
                    pastHours: SpotGuideStore.scrubPastHours)
                guard !Task.isCancelled else { return }
                (axis, day) = await Task.detached(priority: .userInitiated) {
                    let axis = field.map(\.currents).max { $0.count < $1.count }?.map(\.at) ?? []
                    let slots = Self.slotIndex(of: axis)
                    var day = Self.blankDay(hours: axis.count, points: count)
                    for (coordIndex, point) in field.enumerated() where coordIndex < count {
                        for row in point.currents {
                            guard let slot = slots[row.at] else { continue }
                            day[slot].speeds[coordIndex] = row.speedKn
                            day[slot].directions[coordIndex] = row.directionDeg
                        }
                    }
                    return (axis, day)
                }.value
            case .off:
                return
            }
            guard !Task.isCancelled else { return }
            // Whatever the old field's rebuild was working towards, it is
            // about to be answering for the wrong rectangle — retired here,
            // in the same breath as the field it belonged to.
            cancelRebuild()
            hourAxis = axis
            hourly = day
            fieldRegion = target
            loadedVisible = visible
            drawWindow = Self.paddedWindow(for: visible)
            loadedLayer = layer
            fieldStamp = UUID()
            bookedIndex = nil
            displayedIndex = nil
            // New rectangle, new quads: the geometry is redrawn against it
            // by the first rebuild, not carried over from the old one.
            layout = nil
            // The rectangle just changed, so the coastline drawn for the old
            // one is the wrong shape. Redrawn against the new field before
            // anything asks it a question.
            waterMask = WaterMask()
            if layer == .currents, Self.masksLand { loadMask() }
            if axis.isEmpty {
                // An answer with no hours at all — an inland window under
                // the ocean model. The old region's cells must go with it,
                // or the wash keeps painting water that isn't there.
                cells = []
                field = nil
            } else {
                apply()
            }
            isLoading = false
        }
    }

    /// An empty day, one row per hour and one slot per grid point.
    nonisolated private static func blankDay(hours: Int, points: Int)
    -> [(speeds: [Double?], directions: [Double?])] {
        (0..<hours).map { _ in
            (speeds: [Double?](repeating: nil, count: points),
             directions: [Double?](repeating: nil, count: points))
        }
    }

    /// Hour to row, for laying each point's series onto the shared axis.
    nonisolated private static func slotIndex(of axis: [Date]) -> [Date: Int] {
        Dictionary(axis.enumerated().map { ($1, $0) }) { first, _ in first }
    }

    private func gridCoordinates(for region: MKCoordinateRegion) -> [Geo.Coordinate] {
        var out: [Geo.Coordinate] = []
        for row in 0..<FlowMapScreen.rows {
            for column in 0..<FlowMapScreen.columns {
                out.append(Geo.Coordinate(
                    latitude: max(-89, min(89,
                        region.center.latitude - region.span.latitudeDelta / 2
                        + region.span.latitudeDelta * Double(row) / Double(FlowMapScreen.rows - 1))),
                    longitude: region.center.longitude - region.span.longitudeDelta / 2
                        + region.span.longitudeDelta * Double(column) / Double(FlowMapScreen.columns - 1)
                ))
            }
        }
        return out
    }

    /// The raster builder's bilinear walk, stopped at cell resolution —
    /// the geometry half, run once per field rectangle.
    ///
    /// Everything here is about *where*, and nothing about how hard the
    /// wind is blowing: the quads, the edge feather, and the land test that
    /// decides whether a quad exists at all. All three survive a change of
    /// hour untouched, and all three are what used to make scrubbing
    /// expensive — seventeen hundred four-coordinate arrays allocated and
    /// thrown away for every hour the thumb crossed, plus a coastline
    /// lookup apiece.
    /// `insetLon` is half the overlap MapKit leaves between abutting
    /// polygons, in degrees of longitude — see the call site for where it
    /// comes from. Zero disables the correction.
    nonisolated private static func buildLayout(region: MKCoordinateRegion,
                                                mask: WaterMask,
                                                insetLon: Double,
                                                window: MKCoordinateRegion?) -> [CellLayout] {
        let columns = FlowMapScreen.columns
        let rows = FlowMapScreen.rows
        let upsample = drawUpsample(field: region, window: window)
        let cellColumns = (columns - 1) * upsample
        let cellRows = (rows - 1) * upsample
        // The feather is a width of *field*, not a count of cells — so it
        // has to widen as the cells get finer, or cutting finer would turn
        // the field's soft edge into a wall.
        let featherCells = 2.5 * Double(upsample) / Double(minUpsample)

        let south = region.center.latitude - region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let latStep = region.span.latitudeDelta / Double(cellRows)
        let lonStep = region.span.longitudeDelta / Double(cellColumns)

        // The seam. MapKit fills a polygon about a pixel past its own edge,
        // so two quads that share an edge both paint the pixels along it —
        // and the wash is translucent, where painting twice is not painting
        // once. Half-opacity over half-opacity is three-quarters, so every
        // shared edge came out brighter than the field either side of it: a
        // faint grid on the light basemap, a lit one on the dark basemap,
        // which is what a rider photographed. Pulling each quad in by that
        // one pixel lets them meet instead of overlap.
        //
        // A pixel, not a fraction of a cell: the overlap is a fact about the
        // screen, not about the field, so a percentage would be right at one
        // zoom and wrong at every other. Measured on a simulator, the seam
        // went from +53% of the field's own brightness to under a per cent.
        let insetLat = insetLon * cos(region.center.latitude * .pi / 180)

        // Only the drawn slice is built — quads outside the window are not
        // dimmed or simplified, they are never made, because off screen they
        // cost MapKit exactly what a visible one costs. Their indices are
        // still counted from the field's own corner, so `ringAlpha` measures
        // the field's edge and the feather does not travel with the window.
        //
        // Walked as index ranges rather than the whole field with a test
        // inside it. Cutting finer multiplies the field's cells by the
        // square, and at the zoom where cutting finer matters the window is
        // a thousandth of the field — so a loop over the field would spend a
        // million iterations to keep four hundred. These ranges are what let
        // the resolution above be chosen freely.
        func range(_ lo: Double, _ hi: Double, step: Double, origin: Double, count: Int) -> Range<Int> {
            guard step > 0 else { return 0..<count }
            let first = max(0, Int(((lo - origin) / step).rounded(.down)) - 1)
            let last = min(count, Int(((hi - origin) / step).rounded(.up)) + 1)
            return first < last ? first..<last : 0..<0
        }
        let rowRange = window.map {
            range($0.center.latitude - $0.span.latitudeDelta / 2,
                  $0.center.latitude + $0.span.latitudeDelta / 2,
                  step: latStep, origin: south, count: cellRows)
        } ?? 0..<cellRows
        let columnRange = window.map {
            range($0.center.longitude - $0.span.longitudeDelta / 2,
                  $0.center.longitude + $0.span.longitudeDelta / 2,
                  step: lonStep, origin: west, count: cellColumns)
        } ?? 0..<cellColumns

        var out: [CellLayout] = []
        out.reserveCapacity(rowRange.count * columnRange.count)
        for cellRow in rowRange {
            for cellColumn in columnRange {
                let latitude = south + Double(cellRow) * latStep
                let longitude = west + Double(cellColumn) * lonStep

                // A cell the elevation model calls dry is not painted at
                // all. Unknown — a zoom too wide to mask, or a coastline
                // still being drawn — paints as before: the wash arriving a
                // moment before the coastline is better than a map that
                // blinks.
                let centre = CLLocationCoordinate2D(latitude: latitude + latStep / 2,
                                                    longitude: longitude + lonStep / 2)
                if mask.isWater(centre) == false { continue }

                // The feather: the outer two rings of cells fade out, so
                // the field ends the way the raster's does — a soft edge
                // that says "this window stops", not a painted wall.
                let ring = min(min(cellRow, cellRows - 1 - cellRow),
                               min(cellColumn, cellColumns - 1 - cellColumn))


                out.append(CellLayout(
                    id: cellRow * cellColumns + cellColumn,
                    gx: (Double(cellColumn) + 0.5) / Double(upsample),
                    gy: (Double(cellRow) + 0.5) / Double(upsample),
                    coordinates: [
                        CLLocationCoordinate2D(latitude: latitude + insetLat,
                                               longitude: longitude + insetLon),
                        CLLocationCoordinate2D(latitude: latitude + insetLat,
                                               longitude: longitude + lonStep - insetLon),
                        CLLocationCoordinate2D(latitude: latitude + latStep - insetLat,
                                               longitude: longitude + lonStep - insetLon),
                        CLLocationCoordinate2D(latitude: latitude + latStep - insetLat,
                                               longitude: longitude + insetLon),
                    ],
                    ringAlpha: washAlpha * min(1, (Double(ring) + 0.5) / featherCells)))
            }
        }
        return out
    }

    /// The clock half: one hour's speeds, sampled onto a layout that
    /// already exists.
    ///
    /// No allocation per cell beyond the output — the quads are handed on
    /// by reference, which is the point of splitting them out. A whole
    /// field is a few thousand multiplies, which is why the throttle in
    /// `drainRebuilds` is about MapKit's diffing rather than this.
    nonisolated private static func colourCells(_ layout: [CellLayout], speeds: [Double?],
                                                layer: WashLayer) -> [Cell] {
        let columns = FlowMapScreen.columns
        let rows = FlowMapScreen.rows

        /// Bilinear sample at fractional grid coordinates, with however
        /// much of the water it could actually see.
        ///
        /// The ocean model answers nil over land, and its nodes here are
        /// kilometres apart — so a cell straddling a shoreline used to be
        /// dropped outright the moment one corner fell on the beach. That is
        /// what drew the coast as a staircase of hard rectangles: not the
        /// water's shape, the sampling grid's. Now a cell keeps whatever
        /// corners answered, weighted the same bilinear way, and reports the
        /// weight it managed — so the wash thins out across the last
        /// kilometre instead of ending on a right angle.
        func sample(gx: Double, gy: Double) -> (knots: Double, coverage: Double)? {
            let column0 = min(Int(gx), columns - 2)
            let row0 = min(Int(gy), rows - 2)
            let tx = gx - Double(column0)
            let ty = gy - Double(row0)
            // Unrolled onto locals rather than an array of tuples: this runs
            // seventeen hundred times per hour and the array was a heap
            // allocation each pass, which is most of what a scrubbed hour
            // used to cost.
            let s00 = speeds[row0 * columns + column0]
            let s10 = speeds[row0 * columns + column0 + 1]
            let s01 = speeds[(row0 + 1) * columns + column0]
            let s11 = speeds[(row0 + 1) * columns + column0 + 1]
            let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty)
            let w01 = (1 - tx) * ty, w11 = tx * ty

            // The nearest node has a veto. Averaging live corners alone
            // paints straight over a headland: downtown San Francisco sits
            // between nodes that are all in water — the bay one side, the
            // ocean the other — so the wash ran up Market Street. Whichever
            // node the cell sits closest to is the one that decides whether
            // this is water at all; the rest only shade it.
            var nearestWeight = w00, nearest = s00
            if w10 > nearestWeight { nearestWeight = w10; nearest = s10 }
            if w01 > nearestWeight { nearestWeight = w01; nearest = s01 }
            if w11 > nearestWeight { nearestWeight = w11; nearest = s11 }
            guard nearest != nil else { return nil }

            var total = 0.0, weight = 0.0
            if let s00 { total += s00 * w00; weight += w00 }
            if let s10 { total += s10 * w10; weight += w10 }
            if let s01 { total += s01 * w01; weight += w01 }
            if let s11 { total += s11 * w11; weight += w11 }
            // Under a quarter of the cell is a cell that is mostly land.
            guard weight > 0.25 else { return nil }
            return (total / weight, weight)
        }

        var out: [Cell] = []
        out.reserveCapacity(layout.count)
        for cell in layout {
            guard let found = sample(gx: cell.gx, gy: cell.gy) else { continue }
            // The feather again, along the coast this time, where coverage
            // rather than position decides: a cell the model half-saw is
            // painted half as strongly.
            let alpha = cell.ringAlpha * min(1, (found.coverage - 0.25) / 0.45 + 0.25)
            out.append(Cell(id: cell.id, coordinates: cell.coordinates,
                            color: smoothColour(for: found.knots, layer: layer).opacity(alpha)))
        }
        return out
    }
}

// MARK: - The living streaks

/// The reference apps' animation, honestly translated: a couple hundred
/// dots streaming with the field, each a short comet — dim tail, bright
/// head — advected through the same bilinear surface the wash is coloured
/// by. An overlay on the glass, not map content: sixty frames a second of
/// map-content diffing is the one thing MapKit must never be asked for,
/// so the canvas re-registers every particle through the proxy each frame
/// and the flow stays glued to the world through pan, zoom and rotation.
struct WashParticleLayer: View {
    let field: WindWashModel.Field
    let proxy: MapProxy

    /// A plain reference type deliberately outside observation:
    /// TimelineView is the clock, the canvas advances the sim while
    /// drawing it, and no SwiftUI dependency graph churns per frame.
    @State private var sim = WashParticleSim()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                // The viewport in grid space — all four corners, so a
                // rotated camera still bounds correctly. The field is
                // clamped to 45 km deep; zoomed to a street the view is
                // under a percent of that, and particles scattered over
                // the whole field would statistically never be on screen.
                // Bounding the sim to the view keeps the comet density
                // and pace constant at every zoom.
                let corners = [CGPoint.zero,
                               CGPoint(x: size.width, y: 0),
                               CGPoint(x: 0, y: size.height),
                               CGPoint(x: size.width, y: size.height)]
                    .compactMap { proxy.convert($0, from: .local) }
                guard corners.count == 4 else { return }
                let gridCorners = corners.map { field.grid(of: $0) }
                let bounds = WashParticleSim.Bounds(
                    minGX: max(0, gridCorners.map(\.gx).min() ?? 0),
                    maxGX: min(Double(field.columns - 1), gridCorners.map(\.gx).max() ?? 0),
                    minGY: max(0, gridCorners.map(\.gy).min() ?? 0),
                    maxGY: min(Double(field.rows - 1), gridCorners.map(\.gy).max() ?? 0),
                    visibleLatSpan: (corners.map(\.latitude).max() ?? 0)
                        - (corners.map(\.latitude).min() ?? 0))
                sim.advance(to: timeline.date, in: field, bounds: bounds)
                for particle in sim.particles where particle.fade > 0.02 {
                    guard let head = proxy.convert(
                            field.coordinate(gx: particle.gx, gy: particle.gy), to: .local),
                          let tail = proxy.convert(
                            field.coordinate(gx: particle.tailGX, gy: particle.tailGY), to: .local),
                          head.x > -24, head.x < size.width + 24,
                          head.y > -24, head.y < size.height + 24
                    else { continue }
                    // The comet: a tail that fades to nothing along its own
                    // length, and a head bright enough to carry the screen —
                    // a soft halo under a hot core. Under it all, a dark
                    // twin nudged half a point down: the shadow that keeps
                    // a white comet legible over pale wash and white chart
                    // alike — drawn as geometry, not a blur filter, because
                    // two hundred blurred strokes a frame is a heater.
                    // A comet slow enough that its tail is sub-pixel has
                    // no tail: at that speed the honest picture is a dot
                    // drifting, and a hairline shorter than its own width
                    // only aliases.
                    let reach = hypot(head.x - tail.x, head.y - tail.y)
                    guard reach > 2 else {
                        context.fill(
                            Path(ellipseIn: CGRect(x: head.x - 2.9, y: head.y - 2.3,
                                                   width: 5.8, height: 5.8)),
                            with: .color(.black.opacity(0.22 * particle.fade)))
                        context.fill(
                            Path(ellipseIn: CGRect(x: head.x - 1.4, y: head.y - 1.4,
                                                   width: 2.8, height: 2.8)),
                            with: .color(.white.opacity(particle.fade)))
                        continue
                    }

                    var shadow = Path()
                    shadow.move(to: CGPoint(x: tail.x, y: tail.y + 0.6))
                    shadow.addLine(to: CGPoint(x: head.x, y: head.y + 0.6))
                    context.stroke(
                        shadow,
                        with: .linearGradient(
                            Gradient(colors: [.black.opacity(0),
                                              .black.opacity(0.3 * particle.fade)]),
                            startPoint: tail, endPoint: head),
                        style: StrokeStyle(lineWidth: 2.7, lineCap: .round))
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - 2.9, y: head.y - 2.3,
                                               width: 5.8, height: 5.8)),
                        with: .color(.black.opacity(0.22 * particle.fade)))

                    var streak = Path()
                    streak.move(to: tail)
                    streak.addLine(to: head)
                    context.stroke(
                        streak,
                        with: .linearGradient(
                            Gradient(colors: [.white.opacity(0),
                                              .white.opacity(0.75 * particle.fade)]),
                            startPoint: tail, endPoint: head),
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - 2.6, y: head.y - 2.6,
                                               width: 5.2, height: 5.2)),
                        with: .color(.white.opacity(0.3 * particle.fade)))
                    context.fill(
                        Path(ellipseIn: CGRect(x: head.x - 1.4, y: head.y - 1.4,
                                               width: 2.8, height: 2.8)),
                        with: .color(.white.opacity(particle.fade)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The particle pool, in the field's own grid coordinates so the sampler
/// advects them directly. Spawn scatter is honest randomness — this is
/// animation, where shimmer is the point, and no two launches match.
final class WashParticleSim {

    struct Particle {
        var gx: Double
        var gy: Double
        var tailGX: Double
        var tailGY: Double
        var age: Double
        var lifetime: Double
        var fade: Double = 0
    }

    /// The viewport, in the field's grid coordinates, plus the visible
    /// latitude span that paces the animation.
    struct Bounds {
        let minGX: Double
        let maxGX: Double
        let minGY: Double
        let maxGY: Double
        let visibleLatSpan: Double
    }

    private(set) var particles: [Particle] = []
    private var lastTick: TimeInterval?
    private var fieldID: UUID?
    private static let count = 220

    /// How many seconds of travel the tail spans, ramped with the speed:
    /// a stub at the bottom of the fluid's range, a long streak at the top.
    /// Combined with a velocity already proportional to speed, drawn tail
    /// length grows faster than the speed does — which is the whole read.
    private static func tailReach(forKnots knots: Double,
                                  in flow: WindWashModel.Flow) -> Double {
        let ramp = flow.tailRamp
        let t = min(1, max(0, (knots - ramp.from) / max(0.01, ramp.to - ramp.from)))
        return 0.35 + 0.65 * t
    }

    func advance(to date: Date, in field: WindWashModel.Field, bounds: Bounds) {
        let now = date.timeIntervalSinceReferenceDate
        let dt = min(0.1, max(0, now - (lastTick ?? now)))
        lastTick = now

        if fieldID != field.id {
            // A fresh field: reseed everywhere at once, ages staggered so
            // the flow starts mid-stream instead of pulsing.
            fieldID = field.id
            particles = (0..<Self.count).map { _ in
                Self.spawn(in: field, bounds: bounds, staggered: true)
            }
        }

        // A soft margin, so a comet drifting just off-screen finishes
        // there instead of vanishing at the glass edge.
        let marginX = (bounds.maxGX - bounds.minGX) * 0.12 + 0.02
        let marginY = (bounds.maxGY - bounds.minGY) * 0.12 + 0.02

        for index in particles.indices {
            particles[index].age += dt
            let particle = particles[index]
            guard particle.age <= particle.lifetime,
                  particle.gx >= bounds.minGX - marginX, particle.gx <= bounds.maxGX + marginX,
                  particle.gy >= bounds.minGY - marginY, particle.gy <= bounds.maxGY + marginY,
                  let flow = field.vector(gx: particle.gx, gy: particle.gy)
            else {
                particles[index] = Self.spawn(in: field, bounds: bounds, staggered: false)
                continue
            }
            let speed = (flow.u * flow.u + flow.v * flow.v).squareRoot()
            // Slack water and dead calm carry no comet at all.
            guard speed > field.flow.stillKn else {
                particles[index] = Self.spawn(in: field, bounds: bounds, staggered: false)
                continue
            }

            let phase = particle.age / particle.lifetime
            particles[index].fade = max(0, min(1, min(phase / 0.15, (1 - phase) / 0.3)))

            // Degrees per second, scaled from the *visible* span so the
            // pace reads the same on a street as on a sea — but against an
            // absolute reference speed, never the field's own maximum.
            // Normalising by the maximum was the bug the flow could not
            // shake: it made a six-knot afternoon and a thirty-knot gale
            // stream at exactly the same rate, because each field's
            // fastest node was always the one crossing in `crossSeconds`.
            // The reference belongs to the fluid: eighteen knots of air and
            // one and a bit of water are each an ordinary strong day, and
            // pacing the tide by the wind's yardstick left it looking dead.
            let cellLat = field.region.span.latitudeDelta / Double(field.rows - 1)
            let cellLon = field.region.span.longitudeDelta / Double(field.columns - 1)
            let degreesPerKnot = max(bounds.visibleLatSpan, 0.0001)
                / (field.flow.crossSeconds * field.flow.referenceKn)
            let stretch = 1 / max(0.2, cos(field.region.center.latitude * .pi / 180))
            let gridVX = flow.u * degreesPerKnot * stretch / cellLon
            let gridVY = flow.v * degreesPerKnot / cellLat

            particles[index].gx += gridVX * dt
            particles[index].gy += gridVY * dt
            // The tail is velocity times reach, and the reach itself grows
            // with the wind — so drawn length rises faster than speed
            // alone: light air leaves a stub, a gale leaves a streak.
            let reach = Self.tailReach(forKnots: speed, in: field.flow)
            particles[index].tailGX = particles[index].gx - gridVX * reach
            particles[index].tailGY = particles[index].gy - gridVY * reach
        }
    }

    private static func spawn(in field: WindWashModel.Field, bounds: Bounds,
                              staggered: Bool) -> Particle {
        // A few tries to land on live water — a current field is half land,
        // and spawning blind there would thin the visible flow.
        for _ in 0..<8 {
            let gx = Double.random(in: bounds.minGX...max(bounds.minGX, bounds.maxGX))
            let gy = Double.random(in: bounds.minGY...max(bounds.minGY, bounds.maxGY))
            guard field.vector(gx: gx, gy: gy) != nil else { continue }
            let lifetime = Double.random(in: 2.2...4.5)
            return Particle(gx: gx, gy: gy, tailGX: gx, tailGY: gy,
                            age: staggered ? Double.random(in: 0..<lifetime) : 0,
                            lifetime: lifetime)
        }
        // A viewport with no live node in it still needs a particle to
        // retire quietly.
        return Particle(gx: bounds.minGX, gy: bounds.minGY,
                        tailGX: bounds.minGX, tailGY: bounds.minGY, age: 1, lifetime: 1)
    }
}
