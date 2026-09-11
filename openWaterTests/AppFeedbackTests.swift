import OpenWaterCore
import XCTest
@testable import openWater

/// What the app sends must match what the rules accept.
///
/// `appFeatureFeedback` predates this app: it is the collection the website's
/// own feedback form writes to, and its rule was deployed with the website.
/// That is a feature — it means the bug button on every screen needed no new
/// rule and no deploy to start working — and it is also the risk, because the
/// rule is in a repository this one does not build. `hasOnly` on the key list
/// and `type in [...]` on the type both fail closed: a field or a type value
/// added here without a matching change there does not degrade, it 403s
/// *every* submission from *every* rider.
///
/// So the contract is pinned here, the same way `SessionFeedbackTests` pins
/// the session reports. If one of these fails, the change is not wrong — it
/// just cannot ship until the rules are updated and deployed to match.
///
/// Read from `firestore.rules` in the website repository, 10 August 2026.
final class AppFeedbackTests: XCTestCase {

    /// Exactly the keys the deployed `hasOnly` list allows.
    private let allowedKeys: Set<String> = [
        "type", "title", "details", "platform", "version", "contact", "createdAt",
    ]

    /// Exactly the values the deployed `type in [...]` clause allows.
    private let allowedTypes: Set<String> = ["feature", "improvement", "bug", "other"]

    private func report(text: String = "The wind arrows are hard to read at a glance.",
                        screen: String = "Models") -> AppFeedback.Report {
        AppFeedback.Report(kind: .improvement, screen: screen, text: text)
    }

    // MARK: The document

    func testEveryFieldSentIsOneTheRulesAllow() {
        let fields = AppFeedback.fields(for: report())
        let extra = Set(fields.keys).subtracting(allowedKeys)

        XCTAssertTrue(extra.isEmpty, """
            Sending field(s) the deployed rules reject: \(extra.sorted()).
            hasOnly means this 403s every submission, not just this one.
            Update firestore.rules in the website repo and deploy before shipping.
            """)
    }

    func testEveryKindIsATypeTheRulesAllow() {
        for kind in AppFeedback.Kind.allCases {
            XCTAssertTrue(allowedTypes.contains(kind.rawValue), """
                \(kind.rawValue) is not in the deployed type list.
                Every report of this kind would be refused.
                """)
        }
    }

    func testTheFieldsTheRulesRequireAreAlwaysPresent() {
        // `title`, `type`, `details` and `createdAt` are not guarded by the
        // rule's optional-field helper: a document without them is refused.
        let fields = AppFeedback.fields(for: report())
        for key in ["type", "title", "details", "createdAt"] {
            XCTAssertNotNil(fields[key], "\(key) is required by the rule")
        }
    }

    func testTheTitleIsNeverEmpty() {
        // The rule demands `title.size() > 0`, and a screen name is passed in
        // by a caller that could always be wrong about having one.
        let fields = AppFeedback.fields(for: report(screen: "   "))
        let title = fields["title"]?["stringValue"] as? String

        XCTAssertEqual(title?.isEmpty, false,
                       "An empty title is refused outright, so there has to be a fallback")
    }

    func testOptionalFieldsAreOmittedRatherThanSentEmpty() {
        var bare = report()
        bare.contact = "   "
        let fields = AppFeedback.fields(for: bare)

        XCTAssertNil(fields["contact"], "A blank email should be absent, not an empty string")
    }

    // MARK: Bounds the rules enforce

    func testLongTextIsCutToTheLimitTheRulesAccept() {
        let fields = AppFeedback.fields(for: report(text: String(repeating: "a", count: 9000)))
        let details = fields["details"]?["stringValue"] as? String

        XCTAssertEqual(details?.count, 4000,
                       "Over 4000 the rules reject the whole report rather than truncating")
    }

    /// The camera reports send the cam's name and URL with the note. They
    /// ride in `details` because the rule's key list is closed, which means
    /// they spend the rider's 4000 characters — so the cap has to be taken on
    /// the two together. Taken separately, a long note and a long URL would
    /// add up to over 4000 and the rule would refuse the whole report.
    func testContextAndWordsShareTheDetailsLimit() {
        var long = report(text: String(repeating: "a", count: 3900))
        long.context = String(repeating: "c", count: 300)
        let details = AppFeedback.fields(for: long)["details"]?["stringValue"] as? String

        XCTAssertEqual(details?.count, 4000,
                       "Context and words must be capped together, not one after the other")
    }

    func testContextLeadsTheDetailsSoATicketSaysWhatItIsAbout() {
        var withCam = report(text: "Black rectangle, no picture.")
        withCam.context = "Camera: Ditch Plains\nSource: https://example.com/cam"
        let details = AppFeedback.fields(for: withCam)["details"]?["stringValue"] as? String

        XCTAssertEqual(details,
                       "Camera: Ditch Plains\nSource: https://example.com/cam"
                       + "\n\nBlack rectangle, no picture.")
    }

    func testNoContextLeavesTheDetailsExactlyAsTheRiderTypedThem() {
        let details = AppFeedback.fields(for: report(text: "Hard to read."))["details"]?["stringValue"] as? String

        XCTAssertEqual(details, "Hard to read.",
                       "A report with no context must not gain leading whitespace")
    }

    func testALongScreenNameIsCutToTheTitleLimit() {
        let fields = AppFeedback.fields(for: report(screen: String(repeating: "s", count: 400)))
        let title = fields["title"]?["stringValue"] as? String

        XCTAssertEqual(title?.count, 200)
    }

    func testThePlatformStringFitsTheRulesCeiling() {
        // Twenty characters, and the rule refuses the document over it — so a
        // caller handing in something longer must be trimmed, not trusted.
        let fields = AppFeedback.fields(for: report(), platform: "iOS 26.0 on something very long indeed")
        let platform = fields["platform"]?["stringValue"] as? String

        XCTAssertEqual(platform?.count, 20)
    }

    func testTheDocumentEncodesAsJSON() {
        let fields = AppFeedback.fields(for: report())
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["fields": fields]))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["fields": fields]))
    }

    // MARK: Identifiers

    func testIdentifiersDoNotRepeat() {
        let ids = (0..<500).map { _ in AppFeedback.testIdentifier() }
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
