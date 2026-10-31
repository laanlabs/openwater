import Foundation
import Testing
@testable import openWater

/// What the phone can say about a watch app that is not on the watch.
///
/// The first report: "openWater never shows up in my Watch app". Nothing on
/// the phone could say why, because nothing on the phone had looked at what
/// the build carried. These pin what it reads off its own bundle.
@MainActor
@Suite("Watch install diagnosis")
struct WatchInstallDiagnosisTests {

    @Test("This build carries the watch app, and says which watchOS it needs")
    func hostBundleCarriesTheWatchApp() throws {
        // The test host is the iPhone app itself, with the "Embed Watch
        // Content" phase done — so this is the check that the phase is still
        // there, as a test rather than as a rider's report.
        let app = try #require(WatchInstallDiagnosis.inspect(bundle: .main).embedded)
        #expect(app.minimumOS.hasPrefix("11"), "the watch app needs \(app.minimumOS)")
        #expect(app.requiredWatchOS == "watchOS 11")
        #expect(app.watchesLeftBehind?.contains("Series 5") == true)
        #expect(app.runsIndependently, "the watch app should be installable from the watch's own App Store")
        #expect(!app.version.isEmpty && app.version != "?")
    }

    @Test("A debug build knows it came from Xcode")
    func debugBuildIsXcode() {
        #expect(WatchInstallDiagnosis.channel(of: .main) == .xcode)
    }

    @Test("A bundle with no watch app reads as none")
    func missingWatchAppIsNil() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(WatchInstallDiagnosis.embeddedApp(in: dir) == nil)
    }

    @Test("The embedded plist is read as written, and an unknown watchOS names no watches")
    func readsThePlist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = dir.appendingPathComponent("Watch/Fake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleShortVersionString": "2.0",
            "MinimumOSVersion": "12.1",
            "WKRunsIndependentlyOfCompanionApp": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))

        let read = try #require(WatchInstallDiagnosis.embeddedApp(in: dir))
        #expect(read.version == "2.0")
        #expect(read.minimumOS == "12.1")
        #expect(read.requiredWatchOS == "watchOS 12")
        #expect(read.watchesLeftBehind == nil)
        #expect(!read.runsIndependently)
    }
}
