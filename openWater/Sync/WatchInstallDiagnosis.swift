import Foundation

/// What this iPhone can work out for itself about a watch app that is not
/// on the paired watch.
///
/// iOS gives an app no way to install its own watch companion, and almost
/// no way to ask why it has not been: WatchConnectivity says paired or not
/// and installed or not, and nothing about the watch itself — not its
/// model, not its watchOS. The first report of "openWater never shows up in
/// the Watch app" was answered from the project file rather than from the
/// phone: the watch app needs watchOS 11, Series 4, Series 5 and the first
/// SE stop at watchOS 10, and the Watch app leaves out an app the watch
/// cannot run without saying so.
///
/// A build does know what it carries, though, and that answers the two
/// questions a rider cannot: whether there is a watch app inside this copy
/// at all, and which watchOS it needs. Both are read off the embedded watch
/// app's own Info.plist rather than typed here, so the number on the screen
/// is the number in the build.
struct WatchInstallDiagnosis: Equatable {

    /// The watch app inside this build.
    struct EmbeddedApp: Equatable {
        let version: String
        /// "11.0", as the plist writes it.
        let minimumOS: String
        /// Whether watchOS will install it from the watch's own App Store,
        /// without going through the Watch app on the phone.
        let runsIndependently: Bool

        /// The major version, said the way the watch's About screen says it.
        var requiredWatchOS: String {
            "watchOS \(minimumOS.split(separator: ".").first.map(String.init) ?? minimumOS)"
        }

        /// Which watches that rules out. A table, because this is the
        /// sentence a rider needs and Apple prints it nowhere near the
        /// Watch app. Nil for a version the table does not know.
        var watchesLeftBehind: String? {
            switch minimumOS.split(separator: ".").first {
            case "10":
                "Apple Watch Series 3 and earlier stop at watchOS 8 and cannot install it."
            case "11", "26":
                "Apple Watch Series 4, Series 5 and the first SE stop at watchOS 10 and cannot install it; Series 6 and later, SE (2nd generation) and Ultra can."
            default:
                nil
            }
        }
    }

    /// Nil when the build carries no watch app, which is a fault in the
    /// build and nothing the rider can fix from the Watch app.
    let embedded: EmbeddedApp?

    /// How this copy of the iPhone app was installed, because the watch app
    /// arrives a different way from each.
    enum Channel: Equatable { case appStore, testFlight, xcode }
    let channel: Channel

    /// The running app's own answer.
    static let current = inspect(bundle: .main)

    static func inspect(bundle: Bundle) -> WatchInstallDiagnosis {
        WatchInstallDiagnosis(embedded: embeddedApp(in: bundle.bundleURL),
                              channel: channel(of: bundle))
    }

    /// The watch app under `Watch/` in an iOS app bundle — where the "Embed
    /// Watch Content" phase puts it — read from its Info.plist.
    static func embeddedApp(in bundleURL: URL) -> EmbeddedApp? {
        let watch = bundleURL.appendingPathComponent("Watch", isDirectory: true)
        guard let apps = try? FileManager.default.contentsOfDirectory(
                  at: watch, includingPropertiesForKeys: nil),
              let app = apps.first(where: { $0.pathExtension == "app" }),
              let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                  as? [String: Any],
              let minimumOS = plist["MinimumOSVersion"] as? String
        else { return nil }
        return EmbeddedApp(
            version: plist["CFBundleShortVersionString"] as? String ?? "?",
            minimumOS: minimumOS,
            runsIndependently: plist["WKRunsIndependentlyOfCompanionApp"] as? Bool ?? false
        )
    }

    /// A debug build came from Xcode whatever receipt it carries — the
    /// sandbox receipt that marks TestFlight is also what a development
    /// install gets, which is the usual trap in TestFlight detection.
    static func channel(of bundle: Bundle) -> Channel {
        #if DEBUG
        return .xcode
        #else
        return receiptURL(of: bundle)?.lastPathComponent == "sandboxReceipt" ? .testFlight : .appStore
        #endif
    }

    /// `appStoreReceiptURL` is deprecated from iOS 18 in favour of StoreKit's
    /// `AppTransaction`, which is asynchronous and wants the network — too
    /// much for one word on a status screen. Marked deprecated itself so the
    /// call inside does not warn.
    @available(iOS, deprecated: 18.0)
    private static func receiptURL(of bundle: Bundle) -> URL? {
        bundle.appStoreReceiptURL
    }
}
