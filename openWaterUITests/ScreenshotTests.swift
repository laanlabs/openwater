import XCTest

/// Captures App Store screenshots.
///
/// Driving the real app through a UI test rather than staging mockups means the
/// screenshots can never claim something the app does not do — every number on
/// them comes from the actual analysis pipeline running on generated track data.
/// It is also repeatable: rerun after a UI change and the whole set regenerates.
///
/// Screenshots are written to the directory given by the `SCREENSHOT_OUTPUT_DIR`
/// environment variable. Writing straight to a path on the host is far simpler
/// than attaching them to the result bundle and extracting them afterwards, and
/// the simulator shares the host filesystem so it just works.
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!
    private var outputDirectory: URL?
    private var deviceName: String = "device"

    override func setUpWithError() throws {
        continueAfterFailure = false

        if let path = ProcessInfo.processInfo.environment["SCREENSHOT_OUTPUT_DIR"] {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outputDirectory = url
        }
        deviceName = ProcessInfo.processInfo.environment["SCREENSHOT_DEVICE"] ?? "device"

        app = XCUIApplication()
        app.launchArguments = ["-openWaterResetData", "-openWaterSeedDemoData"]
        // Keep the status bar identical across runs and devices — App Store
        // screenshots with a real battery percentage and a wandering clock look
        // like holiday snaps rather than product shots.
        app.launchEnvironment["UITEST"] = "1"
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        app.launch()

        // The seed builds two sessions and runs the full analysis on each, which
        // takes a moment on first launch.
        let sessionsTitle = app.staticTexts["Sessions"]
        XCTAssertTrue(sessionsTitle.waitForExistence(timeout: 30), "session list never appeared")
        wait(1.5)

        capture("01-sessions")

        // Open the newest session.
        let firstSession = app.buttons.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Wingfoil")
        ).firstMatch
        if firstSession.waitForExistence(timeout: 10) {
            firstSession.tap()
        } else {
            app.cells.firstMatch.tap()
        }
        // Map tiles come over the network and a screenshot taken before they
        // arrive shows the blank placeholder grid, which is the one thing an
        // App Store screenshot cannot have.
        wait(12)
        capture("02-map")

        // Runs — the Ribbon.
        tapSegment("Runs")
        wait(1.5)
        capture("03-runs")

        // Charts — polar, angles, foiling, glides.
        tapSegment("Charts")
        wait(2)
        capture("04-charts")
        // Scroll to the analysis cards below the fold.
        app.swipeUp()
        wait(1)
        capture("05-analysis")

        // Playback, reached from the map.
        tapSegment("Map")
        wait(2)
        let replay = app.buttons["Replay session"]
        if replay.waitForExistence(timeout: 5) {
            replay.tap()
            wait(3)
            capture("06-playback")
            dismissFullScreen()
        }

        // Records board.
        navigateBack()
        wait(1)
        tapTab("Records")
        wait(1.5)
        capture("07-records")

        // Trends.
        tapTab("Trends")
        wait(1.5)
        capture("08-trends")
    }

    // MARK: - Helpers

    @MainActor
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        // Always attach, so the shots are in the result bundle even when no
        // output directory was given.
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let outputDirectory else { return }
        let url = outputDirectory.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url, options: .atomic)
        } catch {
            XCTFail("could not write \(name): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func tapSegment(_ label: String) {
        let segment = app.buttons[label]
        if segment.waitForExistence(timeout: 5), segment.isHittable {
            segment.tap()
        }
    }

    @MainActor
    private func tapTab(_ label: String) {
        // The tab bar and the segmented control can both carry the same label,
        // so prefer the tab bar's own descendant when there is one.
        let tab = app.tabBars.buttons[label]
        if tab.exists, tab.isHittable {
            tab.tap()
            return
        }
        let fallback = app.buttons[label]
        if fallback.waitForExistence(timeout: 5), fallback.isHittable {
            fallback.tap()
        }
    }

    @MainActor
    private func navigateBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.exists, back.isHittable { back.tap() }
    }

    @MainActor
    private func dismissFullScreen() {
        // The full-screen covers close with an X in the top left.
        let close = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label == %@", "xmark", "Close")
        ).firstMatch
        if close.exists, close.isHittable {
            close.tap()
        } else {
            app.buttons.element(boundBy: 0).tap()
        }
        wait(1)
    }

    private func wait(_ seconds: TimeInterval) {
        // Deliberately a fixed wait rather than an expectation: these are timing
        // the map tiles and chart animations settling, which have no queryable
        // "done" state, and a screenshot taken mid-animation is unusable.
        Thread.sleep(forTimeInterval: seconds)
    }
}
