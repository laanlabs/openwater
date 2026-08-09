import OpenWaterCore
import XCTest
@testable import openWater

/// What the app sends must match what the rules accept.
///
/// The Firestore and Storage rules that accept problem reports live in the
/// website repository, deployed separately from this one. That split has a
/// specific failure mode: `hasOnly` on the key list means a field added here
/// without a matching change there does not degrade gracefully — *every*
/// submission from *every* rider starts coming back 403, and nothing in this
/// repository would catch it. The same goes for the Storage filename pattern.
///
/// So the contract is pinned here. If one of these fails, the change is not
/// wrong — it just cannot ship until the rules are updated and deployed to
/// match, and the failure is the reminder.
///
/// Deployed 9 August 2026, verified live against `openwaterapp-2e0f7`.
final class SessionFeedbackTests: XCTestCase {

    /// Exactly the keys the deployed `hasOnly` list allows.
    private let allowedKeys: Set<String> = [
        "topic", "text", "contact", "session", "sport", "duration", "distance",
        "analysisVersion", "runsDownwind", "runsReaching", "runsUpwind",
        "stretches", "flights", "turns", "falls", "jumps", "foilingFraction",
        "windDirection", "windSource", "recordingPath", "appVersion", "system",
        "createdAt",
    ]

    private func report(text: String = "Says twelve runs, it was six.") -> SessionFeedback.Report {
        SessionFeedback.Report(
            topic: .runs, text: text,
            sessionTitle: "test-5", sport: "wingfoil",
            duration: 8111, distance: 46210, analysisVersion: 12,
            runsDownwind: 48, runsReaching: 64, runsUpwind: 1,
            stretches: 246, flights: 23, turns: 242, falls: 2, jumps: 0,
            foilingFraction: 0.94, windDirection: 232, windSource: "estimatedBidirectional"
        )
    }

    // MARK: The document

    func testEveryFieldSentIsOneTheRulesAllow() {
        let fields = SessionFeedback.fields(for: report(), recordingPath: nil)
        let extra = Set(fields.keys).subtracting(allowedKeys)

        XCTAssertTrue(extra.isEmpty, """
            Sending field(s) the deployed rules reject: \(extra.sorted()).
            hasOnly means this 403s every submission, not just this one.
            Update firestore.rules in the website repo and deploy before shipping.
            """)
    }

    func testAFullReportCarriesEveryFieldTheRulesKnowAbout() {
        var full = report()
        full.contact = "someone@example.com"
        let fields = SessionFeedback.fields(for: full, recordingPath: "feedback/abc.openwater")

        // Not an equality check: a rule may allow a key the app has stopped
        // sending, which is harmless. The other direction is the fatal one.
        XCTAssertEqual(Set(fields.keys), allowedKeys)
    }

    func testOptionalFieldsAreOmittedRatherThanSentEmpty() {
        var bare = report()
        bare.contact = "   "
        bare.windDirection = nil
        bare.windSource = nil
        let fields = SessionFeedback.fields(for: bare, recordingPath: nil)

        XCTAssertNil(fields["contact"], "A blank email should be absent, not an empty string")
        XCTAssertNil(fields["windDirection"])
        XCTAssertNil(fields["windSource"])
        XCTAssertNil(fields["recordingPath"], "No recording means no path claiming one")
    }

    // MARK: Bounds the rules enforce

    func testLongTextIsCutToTheLimitTheRulesAccept() {
        let fields = SessionFeedback.fields(
            for: report(text: String(repeating: "a", count: 9000)), recordingPath: nil)
        let text = fields["text"]?["stringValue"] as? String

        XCTAssertEqual(text?.count, 4000,
                       "Over 4000 the rules reject the whole report rather than truncating")
    }

    func testTheDocumentEncodesAsJSON() throws {
        // A NaN reaches JSONSerialization as unencodable and throws, which the
        // rider sees as "could not send" rather than as the divide-by-zero it
        // was. Guarded, so this holds even for a session with no distance.
        var odd = report()
        odd.foilingFraction = .nan
        odd.windDirection = .infinity

        let fields = SessionFeedback.fields(for: odd, recordingPath: nil)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["fields": fields]))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["fields": fields]))
        XCTAssertNil(fields["windDirection"], "An infinite bearing is not a bearing")
    }

    // MARK: The Storage filename

    /// The bucket rule matches `^[a-f0-9]{20}\.openwater$`, so an identifier
    /// that drifts from that shape means every attached recording is refused
    /// — and, because the upload runs first, the note is refused with it.
    func testIdentifiersMatchTheStorageFilenamePattern() {
        let pattern = try! NSRegularExpression(pattern: "^[a-f0-9]{20}$")

        for _ in 0..<200 {
            let id = SessionFeedback.testIdentifier()
            let range = NSRange(id.startIndex..., in: id)
            XCTAssertNotNil(pattern.firstMatch(in: id, range: range),
                            "\(id) would be rejected by the Storage rule")
        }
    }

    func testIdentifiersDoNotRepeat() {
        let ids = (0..<500).map { _ in SessionFeedback.testIdentifier() }
        XCTAssertEqual(Set(ids).count, ids.count,
                       "A repeat would overwrite — except the rules forbid that, so it would fail to send")
    }
}
