#if DEBUG
import Foundation
import OpenWaterCore
import UIKit

/// Notes on what the analysis got wrong, sent from whatever device is to hand.
///
/// Tuning happens by comparing a session on screen against its page in
/// `openWaterTests/Expectations/`. The comparison happens on the water or on
/// the sofa, on a phone; the tuning happens later, at a desk. Between those
/// two the observation used to be lost, or arrive as "the reaching count
/// looked wrong on one of the Montauk ones".
///
/// So a note goes up with the session it is about and the numbers as they
/// stood when it was written, and `scripts/fetch-feedback.sh` pulls them back
/// down into the expectation pages. The numbers matter as much as the words:
/// "48 downwind runs is nonsense" means nothing six analysis versions later
/// unless it records that it was written when the count *was* 48.
///
/// **Debug only**, the whole file. This is a developer tool and nothing about
/// it should exist in a build a rider installs.
///
/// The security model is `SpotSuggestionClient`'s, and it needs the same
/// treatment in the Firestore rules: create-only into `devFeedback`, every
/// field bounded, no read, no list, no update, no delete. Until that rule
/// exists the writes are rejected — see `docs/OPEN.md`.
enum SessionFeedback {

    /// One note, with the session state it was written against.
    struct Note {
        var session: String                 // "test-5"
        var verdict: Verdict
        var text: String

        // What the app was saying at the time. Without these a note ages into
        // an opinion about numbers nobody can reconstruct.
        var analysisVersion: Int
        var runsDownwind: Int
        var runsReaching: Int
        var runsUpwind: Int
        var stretches: Int
        var flights: Int
        var windDirection: Double?
        var windSource: String?
    }

    /// The shape of the complaint, so a sweep can be sorted without reading
    /// every note.
    enum Verdict: String, CaseIterable, Identifiable {
        case wrong = "Wrong"
        case close = "Close"
        case right = "Right"

        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .wrong: "The numbers do not describe this session"
            case .close: "Roughly right, but something is off"
            case .right: "This matches what I'd say happened"
            }
        }
    }

    enum SubmissionError: LocalizedError {
        case save(Int)

        var errorDescription: String? {
            switch self {
            case .save(403):
                "Rejected by Firestore — the devFeedback rule is probably not deployed yet."
            case .save(let code):
                "Could not save the note (HTTP \(code))."
            }
        }
    }

    /// Build a note from a session as the app currently sees it.
    @MainActor
    static func note(for session: Session, summary: SessionSummary,
                     verdict: Verdict, text: String) -> Note {
        let runs = GroupedRun.group(summary.ribbon.lanes, flights: summary.flights)
        return Note(
            session: session.title ?? session.displayTitle,
            verdict: verdict,
            text: text,
            analysisVersion: summary.analysisVersion,
            runsDownwind: runs.filter { $0.kind == .downwind }.count,
            runsReaching: runs.filter { $0.kind == .reaching }.count,
            runsUpwind: runs.filter { $0.kind == .upwind }.count,
            stretches: summary.ribbon.lanes.count,
            flights: summary.flights.count,
            windDirection: summary.wind?.directionFrom,
            windSource: summary.wind?.source.rawValue
        )
    }

    static func submit(_ note: Note) async throws {
        var fields: [String: [String: Any]] = [
            "session": ["stringValue": String(note.session.prefix(60))],
            "verdict": ["stringValue": note.verdict.rawValue],
            "text": ["stringValue": String(
                note.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))],
            "analysisVersion": ["integerValue": String(note.analysisVersion)],
            "runsDownwind": ["integerValue": String(note.runsDownwind)],
            "runsReaching": ["integerValue": String(note.runsReaching)],
            "runsUpwind": ["integerValue": String(note.runsUpwind)],
            "stretches": ["integerValue": String(note.stretches)],
            "flights": ["integerValue": String(note.flights)],
            "appVersion": ["stringValue": appVersion],
            "device": ["stringValue": await UIDevice.current.model],
            "createdAt": ["stringValue": ISO8601DateFormatter().string(from: Date())],
        ]
        if let direction = note.windDirection {
            fields["windDirection"] = ["doubleValue": direction]
        }
        if let source = note.windSource {
            fields["windSource"] = ["stringValue": source]
        }

        var request = URLRequest(url: URL(string:
            "\(SpotGuideStore.firestoreBase)/devFeedback?key=\(SpotGuideStore.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])

        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SubmissionError.save(code) }
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
#endif
