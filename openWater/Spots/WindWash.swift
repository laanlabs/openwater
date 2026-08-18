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
/// The hard cell edges are the model's own coarseness with the smoothing
/// half-done — banding was already the raster's philosophy; these bands
/// just have corners.
/// What the map's wash is showing, if anything. A picker, not a stack —
/// two translucent fields over one another would say nothing about either.
enum WashLayer: String, CaseIterable {
    case off, wind, currents

    var caption: String? {
        switch self {
        case .off: nil
        case .wind: "Wind wash · Open-Meteo model · now"
        case .currents: "Current wash · Open-Meteo ocean model · now"
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

    private(set) var cells: [Cell] = []
    private(set) var fieldRegion: MKCoordinateRegion?
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var loadedLayer: WashLayer = .off

    /// How much finer the cells are than the model grid. Three keeps a
    /// 60 km field's cells around 2.5 km — contour-ish without asking
    /// MapKit to composite thousands of overlays.
    private static let upsample = 3
    /// The wash's strength, matching the raster's spirit at map-content
    /// depth; the outer rings fade so the field ends in a feather, not
    /// a wall.
    private static let washAlpha = 0.42

    /// The map settled somewhere — refetch if it wandered far enough from
    /// the loaded field, or if the rider switched what the field shows.
    /// Thresholds are the flow map's own.
    func viewSettled(on visible: MKCoordinateRegion, layer: WashLayer) {
        guard layer != .off else { return clear() }
        guard layer != loadedLayer || needsReload(for: visible) else { return }
        reload(for: visible, layer: layer)
    }

    func clear() {
        loadTask?.cancel()
        loadTask = nil
        cells = []
        fieldRegion = nil
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
            // One hour deep, not the flow map's twenty-four: this wash
            // means *now*; the scrubbing lives on the flow map.
            var speeds = [Double?](repeating: nil, count: FlowMapScreen.columns * FlowMapScreen.rows)
            switch layer {
            case .wind:
                let field = await OpenMeteo.windAlong(coords, hours: 1)
                guard !Task.isCancelled else { return }
                for index in coords.indices where index < speeds.count {
                    speeds[index] = field[safe: index]?.first?.speedKn
                }
            case .currents:
                // The ocean model answers nil over land, so the current
                // wash paints only the water — the field's own honesty,
                // no land mask needed.
                let field = await OpenMeteo.marineAlong(coords, hours: 1)
                guard !Task.isCancelled else { return }
                for index in coords.indices where index < speeds.count {
                    speeds[index] = field[safe: index]?.currents.first?.speedKn
                }
            case .off:
                return
            }
            cells = Self.buildCells(speeds: speeds, region: target, layer: layer)
            fieldRegion = target
            loadedLayer = layer
            isLoading = false
        }
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
                                   layer: WashLayer) -> [Cell] {
        let columns = FlowMapScreen.columns
        let rows = FlowMapScreen.rows
        let cellColumns = (columns - 1) * upsample
        let cellRows = (rows - 1) * upsample

        func speed(atColumn column: Int, row: Int) -> Double? {
            speeds[row * columns + column]
        }
        /// Bilinear sample at fractional grid coordinates.
        func sample(gx: Double, gy: Double) -> Double? {
            let column0 = min(Int(gx), columns - 2)
            let row0 = min(Int(gy), rows - 2)
            let tx = gx - Double(column0)
            let ty = gy - Double(row0)
            guard let a = speed(atColumn: column0, row: row0),
                  let b = speed(atColumn: column0 + 1, row: row0),
                  let c = speed(atColumn: column0, row: row0 + 1),
                  let d = speed(atColumn: column0 + 1, row: row0 + 1)
            else { return nil }
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
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
                guard let knots = sample(gx: gx, gy: gy) else { continue }

                // The feather: the outer two rings of cells fade out, so
                // the field ends the way the raster's does — a soft edge
                // that says "this window stops", not a painted wall.
                let ring = min(min(cellRow, cellRows - 1 - cellRow),
                               min(cellColumn, cellColumns - 1 - cellColumn))
                let alpha = washAlpha * min(1, (Double(ring) + 0.5) / 2.5)

                let latitude = south + Double(cellRow) * latStep
                let longitude = west + Double(cellColumn) * lonStep
                let band: Color = switch layer {
                case .currents: CurrentPalette.color(for: knots)
                default: Color(uiColor: WindPalette.washColour(for: knots))
                }
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
