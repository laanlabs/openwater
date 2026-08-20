import MapKit
import XCTest
@testable import openWater

/// The wash's zoom arithmetic, without a map or a network under it.
///
/// These four rules decide how often the app talks to Open-Meteo and how much
/// geometry it hands MapKit, and both of those were wrong in shipped code for
/// reasons nobody could see: the reload rule compared the view against a field
/// with a 45 km floor, so it was permanently true and refetched on every pan,
/// and the draw resolution was a constant chosen for one zoom. Neither failure
/// showed up as anything but "the map feels slow". Rules made of constants
/// need a test that names the constants.
@MainActor
final class WindWashTests: XCTestCase {

    /// A square-ish region around a point, sized in degrees of latitude.
    private func region(latSpan: Double, at centre: CLLocationCoordinate2D
                        = .init(latitude: 37.8, longitude: -122.4)) -> MKCoordinateRegion {
        MKCoordinateRegion(center: centre,
                           span: MKCoordinateSpan(latitudeDelta: latSpan,
                                                  longitudeDelta: latSpan * 1.25))
    }

    /// 45 km of latitude, which is the floor `clampedField` holds the field to
    /// and therefore the case every zoomed-in view sits inside.
    private var clampedField: MKCoordinateRegion { region(latSpan: 45_000 / 110_574) }

    // MARK: - Reloading

    /// The bug this replaced. A three-kilometre view inside the clamped field
    /// is a twentieth of it, and the old rule read that ratio as "the view has
    /// changed" — so every settle refetched over data that already covered it.
    func testStayingInsideTheFetchedFieldDoesNotRefetch() {
        let visible = region(latSpan: 3_000 / 110_574)
        XCTAssertFalse(WindWashModel.needsReload(visible: visible,
                                                 field: clampedField,
                                                 loadedVisible: visible))
    }

    /// Panning is free until the view starts running off the rectangle that
    /// was actually fetched.
    func testPanningWithinTheFieldIsFreeAndLeavingItIsNot() {
        let span = 3_000 / 110_574.0
        let loaded = region(latSpan: span)
        // A tenth of the field north — still deep inside it.
        let nearby = region(latSpan: span, at: .init(latitude: 37.8 + clampedField.span.latitudeDelta * 0.1,
                                                    longitude: -122.4))
        XCTAssertFalse(WindWashModel.needsReload(visible: nearby, field: clampedField,
                                                 loadedVisible: loaded))

        // Out past the margin the field can cover.
        let away = region(latSpan: span, at: .init(latitude: 37.8 + clampedField.span.latitudeDelta * 0.45,
                                                  longitude: -122.4))
        XCTAssertTrue(WindWashModel.needsReload(visible: away, field: clampedField,
                                                loadedVisible: loaded))
    }

    /// Zoom is measured against the view the field was sized for, because
    /// that is what set the cell size — not against the field, which has a
    /// floor and so says nothing about the zoom.
    func testZoomIsMeasuredAgainstTheViewTheFieldWasFetchedFor() {
        let loaded = region(latSpan: 3_000 / 110_574)
        XCTAssertFalse(WindWashModel.needsReload(visible: region(latSpan: 4_000 / 110_574),
                                                 field: clampedField, loadedVisible: loaded))
        // Past 1.6x and 0.6x it is a different picture and worth a request.
        XCTAssertTrue(WindWashModel.needsReload(visible: region(latSpan: 6_000 / 110_574),
                                                field: clampedField, loadedVisible: loaded))
        XCTAssertTrue(WindWashModel.needsReload(visible: region(latSpan: 1_500 / 110_574),
                                               field: clampedField, loadedVisible: loaded))
    }

    // MARK: - Re-culling the drawn slice

    /// The window is the view opened out, so the view it was built for sits
    /// well inside it and needs nothing.
    func testAViewInsideItsOwnWindowNeedsNoRecull() {
        let visible = region(latSpan: 3_000 / 110_574)
        let window = WindWashModel.paddedWindow(for: visible)
        XCTAssertFalse(WindWashModel.needsRecull(visible: visible, window: window))
    }

    /// And a pan that carries the view out towards the window's edge does.
    func testLeavingTheDrawnWindowNeedsARecull() {
        let span = 3_000 / 110_574.0
        let visible = region(latSpan: span)
        let window = WindWashModel.paddedWindow(for: visible)
        let away = region(latSpan: span, at: .init(latitude: 37.8 + window.span.latitudeDelta * 0.4,
                                                  longitude: -122.4))
        XCTAssertTrue(WindWashModel.needsRecull(visible: away, window: window))
    }

    /// The window records the zoom it was cut for, and a real zoom change has
    /// to re-cut it or the quads are the wrong size for the screen.
    func testZoomingInsideTheWindowStillNeedsARecull() {
        let window = WindWashModel.paddedWindow(for: region(latSpan: 3_000 / 110_574))
        XCTAssertFalse(WindWashModel.needsRecull(visible: region(latSpan: 3_300 / 110_574),
                                                 window: window))
        XCTAssertTrue(WindWashModel.needsRecull(visible: region(latSpan: 5_000 / 110_574),
                                                window: window))
        XCTAssertTrue(WindWashModel.needsRecull(visible: region(latSpan: 1_800 / 110_574),
                                                window: window))
    }

    // MARK: - How fine to cut it

    /// A view as wide as the field draws the whole field at the resolution
    /// the look was tuned at, and never coarser than it.
    func testAWideViewKeepsTheTunedResolution() {
        let field = clampedField
        let window = WindWashModel.paddedWindow(for: field)
        XCTAssertEqual(WindWashModel.drawUpsample(field: field, window: window),
                       WindWashModel.minUpsample)
    }

    /// Zooming in cuts finer rather than leaving the rider looking at two
    /// quads and the seam between them — which is what a constant did.
    func testZoomingInCutsFiner() {
        let field = clampedField
        let close = WindWashModel.drawUpsample(
            field: field, window: WindWashModel.paddedWindow(for: region(latSpan: 3_000 / 110_574)))
        let closer = WindWashModel.drawUpsample(
            field: field, window: WindWashModel.paddedWindow(for: region(latSpan: 1_000 / 110_574)))
        XCTAssertGreaterThan(close, WindWashModel.minUpsample)
        XCTAssertGreaterThan(closer, close)
    }

    /// However fine it cuts, what reaches MapKit stays near the budget — that
    /// number is the hitch when the hour changes, so it is the one that must
    /// not run away.
    func testTheDrawnCountStaysNearTheBudgetAtEveryZoom() {
        let field = clampedField
        for metres in [800.0, 2_000, 5_000, 12_000, 30_000, 45_000] {
            let visible = region(latSpan: metres / 110_574)
            let window = WindWashModel.paddedWindow(for: visible)
            let upsample = WindWashModel.drawUpsample(field: field, window: window)

            // Cells of the field that fall inside the window, both axes.
            let across = Double((FlowMapScreen.columns - 1) * upsample)
                * min(1, window.span.longitudeDelta / field.span.longitudeDelta)
            let down = Double((FlowMapScreen.rows - 1) * upsample)
                * min(1, window.span.latitudeDelta / field.span.latitudeDelta)
            let drawn = across * down

            // The floor is allowed to overshoot at the widest zoom, where it
            // stops cutting coarser in order to keep the tuned look.
            let ceiling = upsample == WindWashModel.minUpsample
                ? Double((FlowMapScreen.columns - 1) * (FlowMapScreen.rows - 1)
                         * WindWashModel.minUpsample * WindWashModel.minUpsample)
                : Double(WindWashModel.drawBudget) * 1.6
            XCTAssertLessThanOrEqual(drawn, ceiling, "at \(Int(metres)) m across")
        }
    }

    /// Nothing known about the view yet means the whole field at the floor,
    /// rather than a guess.
    func testNoWindowMeansTheWholeFieldAtTheFloor() {
        XCTAssertEqual(WindWashModel.drawUpsample(field: clampedField, window: nil),
                       WindWashModel.minUpsample)
    }
}
