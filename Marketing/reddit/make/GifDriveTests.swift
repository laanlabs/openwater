import XCTest

/// A throwaway driver for marketing captures: walks the app through the
/// screens a recording should show while `simctl io recordVideo` films the
/// simulator. Nothing here asserts — a missed tap should leave a gap in the
/// footage, not stop the recording.
final class GifDriveTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        // The tab bar is the app's own floating one, not a UITabBar, so its
        // tabs are plain buttons.
        _ = app.buttons["Spots"].firstMatch.waitForExistence(timeout: 30)
        pause(1.5)
    }

    /// The real Columbia River session: map, the runs ribbon with its
    /// downwind lanes, then the downwind analysis with its glides.
    @MainActor
    func testDownwind() {
        openSession(containing: "Celilo")
        pause(8)
        segment("Runs"); pause(4)
        app.swipeUp(); pause(2.5)
        segment("Analysis"); pause(2)
        row("Downwind"); pause(5)
        app.swipeUp(); pause(3)
    }

    /// The real SUP foil session at Montauk: map, the ribbon with its rides,
    /// then the wave rides screen.
    @MainActor
    func testSurf() {
        openSession(containing: "SUP Foil")
        pause(8)
        segment("Runs"); pause(4.5)
        segment("Analysis"); pause(2)
        row("Wave rides"); pause(5)
        app.swipeUp(); pause(3)
    }

    /// Spots: search Montauk, open the spot, open its conditions, go to the
    /// cams tab and play one.
    @MainActor
    func testCams() {
        tab("Spots"); pause(4)
        tapButton(label: "Search"); pause(1.2)
        tapButton(containing: "Search spots"); pause(1.2)
        // A spot by name, so the result is a spot page rather than a map area.
        app.typeText("Gin Beach"); pause(3.5)
        let spot = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] %@", "Gin Beach")).firstMatch
        if spot.waitForExistence(timeout: 5), spot.isHittable { spot.tap() } else { tapFirstSpotResult() }
        pause(7)
        tapButton(containing: "Get more info"); pause(5)
        tapButton(label: "Cams"); pause(5)
        // The first row of the list is this spot's own YouTube cam; its text
        // is the surest handle on the row.
        let cam = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Gin Beach (")).firstMatch
        if cam.waitForExistence(timeout: 6) { cam.tap() }
        else if !tapButton(containing: "youtube") { _ = tapButton(containing: "Sunset Beach") }
        pause(10)
        tapButton(label: "Done"); pause(1)
    }

    /// The Columbia River session's upwind analysis, polar and VMG screens —
    /// the numbers other trackers do not have.
    @MainActor
    func testUpwind() {
        openSession(containing: "Celilo")
        pause(6)
        segment("Analysis"); pause(2)
        row("Upwind"); pause(6)
        app.swipeUp(); pause(3)
        navigateBack(); pause(1.5)
        row("Polar"); pause(6)
        app.swipeUp(); pause(3)
        navigateBack(); pause(1.5)
        row("Speed & VMG"); pause(6)
        app.swipeUp(); pause(3)
    }

    /// The real wing-in-the-surf session at Montauk: the ribbon with its
    /// waves, then the wave rides screen.
    @MainActor
    func testWingSurf() {
        openSession(containing: "Wingfoil Surf")
        pause(7)
        segment("Runs"); pause(5)
        app.swipeUp(); pause(2.5)
        segment("Analysis"); pause(2)
        row("Wave rides"); pause(6)
        app.swipeUp(); pause(3)
    }

    // MARK: - Helpers

    @MainActor
    private func navigateBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
    }

    @MainActor
    private func openSession(containing text: String) {
        tab("Sessions"); pause(1)
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        for _ in 0..<7 {
            let row = app.buttons.containing(predicate).firstMatch
            if row.exists, row.isHittable { row.tap(); return }
            app.swipeUp(); pause(0.9)
        }
    }

    @MainActor
    private func segment(_ label: String) {
        // The simulator has been seen dropping the app to the home screen
        // mid-drive; a tap on a backgrounded app lands on the springboard.
        if app.state != .runningForeground { app.activate(); pause(2) }
        let button = app.buttons[label]
        if button.waitForExistence(timeout: 5), button.isHittable { button.tap() }
        pause(1.5)
        if app.state != .runningForeground {
            app.activate(); pause(2)
            if button.exists, button.isHittable { button.tap() }
        }
    }

    @MainActor
    private func row(_ title: String) {
        let link = app.buttons.containing(NSPredicate(format: "label BEGINSWITH[c] %@", title)).firstMatch
        if link.waitForExistence(timeout: 4), link.isHittable { link.tap(); return }
        let text = app.staticTexts[title].firstMatch
        if text.waitForExistence(timeout: 4) { text.tap() }
    }

    @MainActor
    private func tab(_ label: String) {
        let bar = app.tabBars.buttons[label]
        if bar.exists, bar.isHittable { bar.tap(); return }
        // The floating tab bar sits at the foot of the screen; the same word
        // can appear higher up as a heading, so take the lowest match.
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .filter { $0.isHittable }
        if let lowest = candidates.max(by: { $0.frame.minY < $1.frame.minY }) { lowest.tap() }
    }

    @MainActor
    @discardableResult
    private func tapButton(label: String) -> Bool {
        let button = app.buttons[label].firstMatch
        guard button.waitForExistence(timeout: 5), button.isHittable else { return false }
        button.tap(); return true
    }

    @MainActor
    @discardableResult
    private func tapButton(containing text: String) -> Bool {
        let button = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        guard button.waitForExistence(timeout: 5), button.isHittable else { return false }
        button.tap(); return true
    }

    /// The first row under the "Spots" header of the search results — the
    /// tab bar carries the same word, so the header is the "Spots" text that
    /// sits in the upper part of the screen.
    @MainActor
    private func tapFirstSpotResult() {
        let height = app.frame.height
        let headers = app.staticTexts.matching(NSPredicate(format: "label == %@", "Spots")).allElementsBoundByIndex
        if let header = headers.first(where: { $0.frame.minY > 60 && $0.frame.minY < height * 0.75 }) {
            let below = app.buttons.allElementsBoundByIndex.filter {
                $0.frame.minY >= header.frame.maxY - 2 && $0.frame.minY < header.frame.maxY + 260 && $0.isHittable
            }
            if let first = below.min(by: { $0.frame.minY < $1.frame.minY }) { first.tap(); return }
        }
        let fallback = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@ AND NOT (label CONTAINS[c] %@)", "Montauk", "spots")).firstMatch
        if fallback.waitForExistence(timeout: 3), fallback.isHittable { fallback.tap() }
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
