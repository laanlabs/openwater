import Foundation
import OpenWaterCore
import OSLog
import UIKit

/// "This screen is confusing" / "it should do X" — from the rider, about the
/// app rather than about one session.
///
/// `SessionFeedback` answers a different question. It is filed *against*
/// numbers that are on screen and carries them, because "the run count was
/// nonsense" means nothing six analysis versions later without the count. Most
/// of the app has no such numbers: a rider looking at the tide chart, the
/// spots map or the settings has an opinion about the screen, and every field
/// in a session report would be blank or a lie.
///
/// So this goes to `appFeatureFeedback`, which already exists and is already
/// deployed — it is what the website's own feedback form writes to — and whose
/// shape is the right one: a type, a title, the words, and what it was sent
/// from. The one thing added here that the web form cannot know is **which
/// screen the rider was looking at**, which goes in the title, because that is
/// the difference between "the forecast is hard to read" and a ticket.
///
/// Same posture as everything else that leaves this app: create-only, never
/// readable, listable or deletable by the app — including its own
/// submissions — and nothing sent that the rider did not type.
enum AppFeedback {

    /// Visible in Console.app filtered to `subsystem:com.laan.labs.openWater
    /// category:feedback`, alongside the session reports. The rider's words
    /// are never logged, only how many characters they wrote.
    static let log = Logger(subsystem: "com.laan.labs.openWater", category: "feedback")

    /// The four the deployed rule accepts. Not a suggestion — `type in [...]`
    /// means anything else is a 403, so this enum's raw values and that list
    /// are one contract, pinned by `AppFeedbackTests`.
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case feature, improvement, bug, other

        var id: String { rawValue }

        /// What a rider would call it, which is not what the rule calls it.
        var label: String {
            switch self {
            case .feature: "Missing something"
            case .improvement: "Could be better"
            case .bug: "Something's broken"
            case .other: "Something else"
            }
        }

        var icon: String {
            switch self {
            case .feature: "plus.circle"
            case .improvement: "wand.and.sparkles"
            case .bug: "ladybug"
            case .other: "ellipsis.bubble"
            }
        }

        var prompt: String {
            switch self {
            case .feature: "What should this screen let you do that it doesn't?"
            case .improvement: "What would make this easier to read or quicker to use?"
            case .bug: "What did you do, and what happened instead?"
            case .other: "What's on your mind about this screen?"
            }
        }
    }

    struct Report {
        var kind: Kind
        /// Where the rider was — "Spots", "Models", "Tide". Carried because a
        /// note without it is a note somebody has to guess the context of.
        var screen: String
        var text: String
        /// Left empty unless the rider wants a reply.
        var contact: String = ""
    }

    static func submit(_ report: Report) async throws {
        let id = identifier()
        let fields = self.fields(for: report, platform: await platform)

        var request = URLRequest(url: URL(string:
            "\(SpotGuideStore.firestoreBase)/appFeatureFeedback?documentId=\(id)&key=\(SpotGuideStore.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])

        log.notice("POST appFeatureFeedback/\(id, privacy: .public) type=\(report.kind.rawValue, privacy: .public) screen=\(report.screen, privacy: .public) chars=\(report.text.count, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            log.error("rejected \(code, privacy: .public): \(body, privacy: .public)")
            throw SessionFeedback.SubmissionError.save(code)
        }
        log.notice("accepted \(id, privacy: .public)")
    }

    /// The document, exactly as Firestore receives it.
    ///
    /// Separate from sending so the contract can be held to the deployed rule
    /// in a test. Every bound here is one the rule enforces: over any of them
    /// and the whole report is refused rather than trimmed.
    static func fields(for report: Report, platform: String = "") -> [String: [String: Any]] {
        // `title` is what a sweep reads first, so it leads with the screen.
        // Non-empty is a rule requirement, not a nicety.
        let screen = report.screen.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String((screen.isEmpty ? "Somewhere in the app" : screen).prefix(200))

        var fields: [String: [String: Any]] = [
            "type": ["stringValue": report.kind.rawValue],
            "title": ["stringValue": title],
            "details": ["stringValue": String(
                report.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))],
            "platform": ["stringValue": String(platform.prefix(20))],
            "version": ["stringValue": String(appVersion.prefix(40))],
            "createdAt": ["stringValue": ISO8601DateFormatter().string(from: Date())],
        ]
        let contact = report.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contact.isEmpty {
            fields["contact"] = ["stringValue": String(contact.prefix(200))]
        }
        return fields
    }

    /// Exposed for the tests, which hold this to the same shape the session
    /// reports use.
    static func testIdentifier() -> String { identifier() }

    private static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20).description
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Twenty characters is the rule's ceiling, which is the system version
    /// and nothing else. `UIDevice.model` is "iPhone" on every iPhone ever
    /// made, so spending the room on it would buy nothing.
    @MainActor
    private static var platform: String {
        "iOS \(UIDevice.current.systemVersion)"
    }
}
