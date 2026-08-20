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

    private(set) var cells: [Cell] = []
    private(set) var field: Field?
    private(set) var fieldRegion: MKCoordinateRegion?
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var loadedLayer: WashLayer = .off

    /// The day the wash was fetched with, kept whole so a route's slider
    /// can scrub the field through its hours without touching the network.
    private var hourAxis: [Date] = []
    private var hourly: [(speeds: [Double?], directions: [Double?])] = []
    /// The instant a route's slider is holding, nil for "now".
    private var scrubbedTo: Date?
    /// Which axis hour the cells/field currently show — the no-op guard
    /// that keeps fifteen-second scrub ticks from rebuilding anything
    /// until the thumb actually crosses an hour.
    private var displayedIndex: Int?
    private var fieldStamp = UUID()
    /// Where the land is, for the layer that must not paint over it. Filled
    /// in tile by tile as a rider looks around, and kept between regions —
    /// the coast does not move, so a tile fetched once serves every zoom and
    /// every hour after it.
    private var waterMask = WaterMask()
    private var maskTask: Task<Void, Never>?
    /// What the rider is looking at, kept so the mask can be judged complete
    /// for *this* view before any of it is trusted.
    private var visibleRegion: MKCoordinateRegion?

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

    /// Cells and field for the hour nearest the scrubbed instant. The
    /// field keeps its stamp across hours so the comets ride the change
    /// instead of reseeding.
    /// `force` is for a mask tile landing: the hour has not changed, but what
    /// counts as water has, so the no-op guard has to be stepped past.
    private func apply(force: Bool = false) {
        guard let region = fieldRegion, !hourAxis.isEmpty else { return }
        let target = scrubbedTo ?? Date()
        let index = hourAxis.indices.min {
            abs(hourAxis[$0].timeIntervalSince(target)) < abs(hourAxis[$1].timeIntervalSince(target))
        } ?? 0
        guard force || index != displayedIndex, hourly.indices.contains(index) else { return }
        displayedIndex = index
        let hour = hourly[index]
        // The mask is the current layer's business only — wind blows over
        // land, and a wind wash that stopped at the shoreline would hide the
        // very thing a rider on a beach is asking about — and only once it
        // covers the whole view, so the coastline arrives in one piece
        // rather than as a chequerboard of loaded tiles.
        let mask = loadedLayer == .currents && Self.masksLand
            && visibleRegion.map { waterMask.covers($0) } == true
            ? waterMask : WaterMask()
        cells = Self.buildCells(speeds: hour.speeds, region: region,
                                layer: loadedLayer, mask: mask)
        field = Field(
            id: fieldStamp,
            flow: loadedLayer == .currents ? .current : .wind,
            mask: mask,
            region: region,
            columns: FlowMapScreen.columns, rows: FlowMapScreen.rows,
            vectors: zip(hour.speeds, hour.directions).map { speed, direction in
                guard let speed, let direction else { return nil }
                let runs = (loadedLayer == .wind ? direction + 180 : direction) * .pi / 180
                return (u: speed * sin(runs), v: speed * cos(runs))
            })
    }

    /// How much finer the cells are than the model grid.
    ///
    /// Three left a 45 km field in cells about two and a half kilometres
    /// across, which at the zoom a rider actually reads a launch at is a
    /// quad the size of a thumbnail — the field stopped looking like water
    /// and started looking like a spreadsheet. Six halves that again in
    /// both directions: 1,440 quads instead of 432, which MapKit composites
    /// without complaint, and the gradient between the model's own nodes
    /// finally reads as a gradient. It adds no information — the model has
    /// what it has — but a smooth surface is the honest picture of a field
    /// that genuinely is smooth, where hard squares imply edges the water
    /// does not have.
    private static let upsample = 6
    /// The wash's strength. The balance that took three tries: heavy
    /// enough that the field's colours read as a surface, light enough
    /// that the muted map's coastline still shows through — you can see
    /// the wind *and* where the wind is. The basemap goes muted while a
    /// wash is up (SpotsTabView), so the wash owns all the colour; the
    /// outer rings fade so the field ends in a feather, not a wall.
    private static let washAlpha = 0.5

    // MARK: The gradient

    /// The Orca look is a gradient, not bands: colour lerped between the
    /// palettes' own band midpoints, so every cell wears its own shade and
    /// the field reads as one continuous surface. The palettes remain the
    /// single source of the colours — this only smooths between them.
    private static func smoothColour(for knots: Double, layer: WashLayer) -> Color {
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
    private static let currentStops: [(at: Double, colour: UIColor)] =
        [0.1, 0.35, 0.65, 1.0, 1.4, 1.9, 2.6].map {
            ($0, UIColor(CurrentPalette.color(for: $0)))
        }

    /// The land-mask switch moved: rebuild what is on screen with the new
    /// answer, and start fetching tiles if it just came on.
    func maskPreferenceChanged(for visible: MKCoordinateRegion, layer: WashLayer) {
        guard layer == .currents else { return }
        visibleRegion = visible
        if Self.masksLand { loadMask(for: visible) }
        apply(force: true)
    }

    /// The map settled somewhere — refetch if it wandered far enough from
    /// the loaded field, or if the rider switched what the field shows.
    /// Thresholds are the flow map's own.
    /// Whether the current wash is cut to the coastline.
    ///
    /// A switch rather than a certainty, because the mask leans on a second
    /// free endpoint: where it is rate-limited, offline or simply wrong about
    /// a stretch of water, a rider should be able to turn it off and get the
    /// field back rather than stare at a hole where their launch is.
    static var masksLand: Bool {
        UserDefaults.standard.object(forKey: "spots.maskLand") as? Bool ?? true
    }

    func viewSettled(on visible: MKCoordinateRegion, layer: WashLayer) {
        guard layer != .off else { return clear() }
        visibleRegion = visible
        if layer == .currents, Self.masksLand { loadMask(for: visible) }
        guard layer != loadedLayer || needsReload(for: visible) else { return }
        reload(for: visible, layer: layer)
    }

    /// Fill in the water mask for what is on screen.
    ///
    /// Twelve tiles a pass, nearest the middle first — that is a bay's worth
    /// at the zoom a rider reads a launch at, and the rest arrives as they
    /// pan. Every tile is a single hundred-point request cached for half a
    /// year, so this is loud exactly once per stretch of coast and silent
    /// for ever after.
    private func loadMask(for visible: MKCoordinateRegion) {
        let wanted = WaterMask.keys(covering: visible).filter { !waterMask.has($0) }
        guard !wanted.isEmpty else { return }
        maskTask?.cancel()
        maskTask = Task { [weak self] in
            // Every tile this view needs, nearest the middle first — the
            // mask is only used once it covers the view, so stopping half
            // way would mean never using it at all. The grain is chosen so
            // that is two dozen requests at most.
            var missed = false
            var gained: [(WaterMask.Key, [Bool])] = []
            for key in wanted {
                guard !Task.isCancelled else { return }
                if let samples = await WaterMask.fetch(key) {
                    gained.append((key, samples))
                } else {
                    missed = true
                }
                // A breath between requests. Open-Meteo counts by the
                // minute, and a burst of two dozen alongside the wash's own
                // fetches is exactly how the first version of this got
                // itself refused and left the coastline unmasked.
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard let self, !Task.isCancelled else { return }
            for (key, samples) in gained { self.waterMask.insert(samples, for: key) }
            if !gained.isEmpty {
                // The hour has not moved, only what counts as water — so
                // this rebuild has to be forced past the no-op guard.
                self.apply(force: true)
            }
            // Something was refused or offline. Nothing here is urgent —
            // the wash paints unmasked meanwhile — so wait out the minute
            // window and try the rest once.
            guard missed, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(65))
            guard !Task.isCancelled else { return }
            var second: [(WaterMask.Key, [Bool])] = []
            for key in wanted where !self.waterMask.has(key) {
                guard !Task.isCancelled else { return }
                if let samples = await WaterMask.fetch(key) { second.append((key, samples)) }
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !second.isEmpty, !Task.isCancelled else { return }
            for (key, samples) in second { self.waterMask.insert(samples, for: key) }
            self.apply(force: true)
        }
    }

    func clear() {
        loadTask?.cancel()
        loadTask = nil
        maskTask?.cancel()
        maskTask = nil
        cells = []
        field = nil
        fieldRegion = nil
        hourAxis = []
        hourly = []
        displayedIndex = nil
        loadedLayer = .off
        isLoading = false
    }

    /// The flow map's drift rule, verbatim.
    private func needsReload(for visible: MKCoordinateRegion) -> Bool {
        guard let field = fieldRegion else { return true }
        let spanRatio = visible.span.latitudeDelta / field.span.latitudeDelta
        let centreShift =
            abs(visible.center.latitude - field.center.latitude) / field.span.latitudeDelta
            + abs(visible.center.longitude - field.center.longitude) / field.span.longitudeDelta
        return spanRatio > 1.3 || spanRatio < 0.55 || centreShift > 0.3
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
            func blank() -> (speeds: [Double?], directions: [Double?]) {
                ([Double?](repeating: nil, count: count),
                 [Double?](repeating: nil, count: count))
            }
            switch layer {
            case .wind:
                let field = await OpenMeteo.windAlong(
                    coords, hours: SpotGuideStore.scrubForecastHours,
                    pastHours: SpotGuideStore.scrubPastHours)
                guard !Task.isCancelled else { return }
                axis = (field.max { $0.count < $1.count })?.map(\.date) ?? []
                day = axis.map { _ in blank() }
                // A hash of the axis, not a linear search per row: three
                // days across sixty-three points is ~4,500 rows, and
                // `firstIndex(of:)` would walk seventy-two dates for each
                // of them on the main actor — a third of a million
                // comparisons where a dictionary costs one.
                let slots = Self.slotIndex(of: axis)
                for (coordIndex, rows) in field.enumerated() where coordIndex < count {
                    for row in rows {
                        guard let slot = slots[row.date] else { continue }
                        day[slot].speeds[coordIndex] = row.speedKn
                        day[slot].directions[coordIndex] = row.directionDeg
                    }
                }
            case .currents:
                // The ocean model answers nil over land, so the current
                // wash paints only the water — the field's own honesty,
                // no land mask needed.
                let field = await OpenMeteo.marineAlong(
                    coords, hours: SpotGuideStore.scrubForecastHours,
                    pastHours: SpotGuideStore.scrubPastHours)
                guard !Task.isCancelled else { return }
                axis = field.map(\.currents).max { $0.count < $1.count }?.map(\.at) ?? []
                day = axis.map { _ in blank() }
                let slots = Self.slotIndex(of: axis)
                for (coordIndex, point) in field.enumerated() where coordIndex < count {
                    for row in point.currents {
                        guard let slot = slots[row.at] else { continue }
                        day[slot].speeds[coordIndex] = row.speedKn
                        day[slot].directions[coordIndex] = row.directionDeg
                    }
                }
            case .off:
                return
            }
            hourAxis = axis
            hourly = day
            fieldRegion = target
            loadedLayer = layer
            fieldStamp = UUID()
            displayedIndex = nil
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

    /// Hour to row, for laying each point's series onto the shared axis.
    private static func slotIndex(of axis: [Date]) -> [Date: Int] {
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

    /// The raster builder's bilinear walk, stopped at cell resolution.
    private static func buildCells(speeds: [Double?], region: MKCoordinateRegion,
                                   layer: WashLayer, mask: WaterMask) -> [Cell] {
        let columns = FlowMapScreen.columns
        let rows = FlowMapScreen.rows
        let cellColumns = (columns - 1) * upsample
        let cellRows = (rows - 1) * upsample

        func speed(atColumn column: Int, row: Int) -> Double? {
            speeds[row * columns + column]
        }
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
            let corners = [
                (speed(atColumn: column0, row: row0), (1 - tx) * (1 - ty)),
                (speed(atColumn: column0 + 1, row: row0), tx * (1 - ty)),
                (speed(atColumn: column0, row: row0 + 1), (1 - tx) * ty),
                (speed(atColumn: column0 + 1, row: row0 + 1), tx * ty),
            ]
            // The nearest node has a veto. Averaging live corners alone
            // paints straight over a headland: downtown San Francisco sits
            // between nodes that are all in water — the bay one side, the
            // ocean the other — so the wash ran up Market Street. Whichever
            // node the cell sits closest to is the one that decides whether
            // this is water at all; the rest only shade it.
            guard let nearest = corners.max(by: { $0.1 < $1.1 }), nearest.0 != nil
            else { return nil }
            var total = 0.0, weight = 0.0
            for (value, w) in corners {
                guard let value else { continue }
                total += value * w
                weight += w
            }
            // Under a quarter of the cell is a cell that is mostly land.
            guard weight > 0.25 else { return nil }
            return (total / weight, weight)
        }

        let south = region.center.latitude - region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let latStep = region.span.latitudeDelta / Double(cellRows)
        let lonStep = region.span.longitudeDelta / Double(cellColumns)

        var out: [Cell] = []
        out.reserveCapacity(cellColumns * cellRows)
        for cellRow in 0..<cellRows {
            for cellColumn in 0..<cellColumns {
                let gx = (Double(cellColumn) + 0.5) / Double(upsample)
                let gy = (Double(cellRow) + 0.5) / Double(upsample)
                guard let found = sample(gx: gx, gy: gy) else { continue }
                let knots = found.knots

                // The feather: the outer two rings of cells fade out, so
                // the field ends the way the raster's does — a soft edge
                // that says "this window stops", not a painted wall. The
                // same trick along the coast, where coverage rather than
                // position decides: a cell the model half-saw is painted
                // half as strongly.
                let ring = min(min(cellRow, cellRows - 1 - cellRow),
                               min(cellColumn, cellColumns - 1 - cellColumn))
                let alpha = washAlpha * min(1, (Double(ring) + 0.5) / 2.5)
                    * min(1, (found.coverage - 0.25) / 0.45 + 0.25)

                let latitude = south + Double(cellRow) * latStep
                let longitude = west + Double(cellColumn) * lonStep

                // A cell the elevation model calls dry is not painted at
                // all. Unknown — a tile still in flight, or a zoom too wide
                // to mask — paints as before: the wash arriving a moment
                // before the coastline is better than a map that blinks.
                let centre = CLLocationCoordinate2D(latitude: latitude + latStep / 2,
                                                    longitude: longitude + lonStep / 2)
                if mask.isWater(centre) == false { continue }

                let band = smoothColour(for: knots, layer: layer)
                out.append(Cell(
                    id: cellRow * cellColumns + cellColumn,
                    coordinates: [
                        CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        CLLocationCoordinate2D(latitude: latitude, longitude: longitude + lonStep),
                        CLLocationCoordinate2D(latitude: latitude + latStep, longitude: longitude + lonStep),
                        CLLocationCoordinate2D(latitude: latitude + latStep, longitude: longitude),
                    ],
                    color: band.opacity(alpha)
                ))
            }
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
