import Foundation
import OpenWaterCore
import UIKit

/// "This run says it did X and it actually did Y" — from the rider, about the
/// session in front of them.
///
/// The analysis is tuned by comparing what the app claims against what
/// somebody who was there remembers. That comparison only ever happens on a
/// phone, right after a session; the tuning happens later at a desk. Between
/// the two the observation was lost, or arrived as "the run count looked
/// wrong on one of them". This carries it across intact.
///
/// **The numbers travel with the words.** "It says 48 downwind runs and that
/// is nonsense" means nothing six analysis versions later unless the note
/// records that the count *was* 48 when it was written.
///
/// ## What is sent, and what is not
///
/// By default: the rider's words, the numbers on screen, and the app and
/// device version. No coordinates, no track, nothing that says where anybody
/// was.
///
/// The recording itself goes only when the rider explicitly asks for it,
/// through a toggle that is off every time and says plainly what it does. A
/// GPS track is where somebody launches, where they live if they recorded
/// from home, and when they are reliably out. It is the most sensitive thing
/// this app holds, and it is never attached by inference — not from a
/// category, not from a previous submission, not from a setting they ticked
/// once.
///
/// The security model is `SpotSuggestionClient`'s: create-only into
/// `sessionFeedback`, create-only into `feedback/` in Storage, never
/// readable, listable or deletable by the app — including its own
/// submissions.
enum SessionFeedback {

    /// What the rider says is wrong, so a sweep can be sorted without reading
    /// every note. Named for what a rider would say, not for the code that
    /// produces it.
    enum Topic: String, CaseIterable, Identifiable, Codable {
        case runs = "Runs"
        case foiling = "Foiling"
        case speed = "Speed & distance"
        case wind = "Wind"
        case turns = "Turns, falls & jumps"
        case other = "Something else"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .runs: "arrow.triangle.turn.up.right.diamond"
            case .foiling: "airplane"
            case .speed: "gauge.with.dots.needle.67percent"
            case .wind: "wind"
            case .turns: "arrow.trianglehead.2.clockwise"
            case .other: "ellipsis.bubble"
            }
        }

        var prompt: String {
            switch self {
            case .runs: "How many runs was it really, and how would you have split them?"
            case .foiling: "What did it get wrong about your flights or time on foil?"
            case .speed: "Which number is off, and what should it be?"
            case .wind: "Where was the wind actually coming from?"
            case .turns: "What did it miss, or count that never happened?"
            case .other: "What happened, and what did you expect to see?"
            }
        }
    }

    /// One report, with the state of the session it is about.
    struct Report {
        var topic: Topic
        var text: String
        /// Left empty unless the rider wants a reply.
        var contact: String = ""
        /// Set only when the rider has explicitly asked to send the recording.
        var recording: Data?

        // The session as the app was describing it. Non-identifying: counts,
        // durations and a wind bearing, no coordinates.
        var sessionTitle: String
        var sport: String
        var duration: TimeInterval
        var distance: Double
        var analysisVersion: Int
        var runsDownwind: Int
        var runsReaching: Int
        var runsUpwind: Int
        var stretches: Int
        var flights: Int
        var turns: Int
        var falls: Int
        var jumps: Int
        var foilingFraction: Double
        var windDirection: Double?
        var windSource: String?
    }

    enum SubmissionError: LocalizedError {
        case recordingUpload
        case save(Int)

        var errorDescription: String? {
            switch self {
            case .recordingUpload:
                "Your notes were not sent because the recording failed to upload. Try again, or send without it."
            case .save(403):
                "The server refused it. If this build is new, the feedback rules may not be deployed yet."
            case .save(let code):
                "Could not send that (HTTP \(code)). Try again in a minute."
            }
        }
    }

    /// Build a report from a session as the app currently sees it.
    @MainActor
    static func report(for session: Session, summary: SessionSummary,
                       topic: Topic, text: String) -> Report {
        let runs = GroupedRun.group(summary.ribbon.lanes, flights: summary.flights)
        return Report(
            topic: topic,
            text: text,
            sessionTitle: session.title ?? session.displayTitle,
            sport: session.sport.rawValue,
            duration: summary.duration,
            distance: summary.distance,
            analysisVersion: summary.analysisVersion,
            runsDownwind: runs.filter { $0.kind == .downwind }.count,
            runsReaching: runs.filter { $0.kind == .reaching }.count,
            runsUpwind: runs.filter { $0.kind == .upwind }.count,
            stretches: summary.ribbon.lanes.count,
            flights: summary.flights.count,
            turns: summary.maneuvers.count,
            falls: summary.fallSummary.count,
            jumps: summary.jumps.count,
            foilingFraction: summary.foil.foilingFraction,
            windDirection: summary.wind?.directionFrom,
            windSource: summary.wind?.source.rawValue
        )
    }

    /// Upload the recording first, then the note.
    ///
    /// That order, so a failed upload never leaves a note claiming a
    /// recording is attached when it is not — the same reasoning as the spot
    /// suggestion pipeline, and the same reason it throws rather than
    /// silently sending a note without it.
    static func submit(_ report: Report) async throws {
        let id = identifier()
        var recordingPath: String?

        if let recording = report.recording {
            guard let path = await upload(recording, named: id) else {
                throw SubmissionError.recordingUpload
            }
            recordingPath = path
        }

        let fields = self.fields(for: report, recordingPath: recordingPath,
                                 system: await systemVersion)

        var request = URLRequest(url: URL(string:
            "\(SpotGuideStore.firestoreBase)/sessionFeedback?documentId=\(id)&key=\(SpotGuideStore.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])

        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SubmissionError.save(code) }
    }

    /// The document, exactly as Firestore receives it.
    ///
    /// Separate from sending because the rules that accept this live in the
    /// website repository, and `hasOnly` on the key list means a field added
    /// here without one added there does not degrade — every submission from
    /// every rider starts failing with a 403. `SessionFeedbackTests` holds
    /// this to the deployed key list so that cannot happen quietly.
    /// `system` is passed in rather than read here: `UIDevice` is
    /// main-actor isolated, and making this async purely to name a phone
    /// model would put an `await` in front of every test that builds a
    /// document.
    static func fields(for report: Report, recordingPath: String?,
                       system: String = "") -> [String: [String: Any]] {
        var fields: [String: [String: Any]] = [
            "topic": ["stringValue": report.topic.rawValue],
            "text": ["stringValue": String(
                report.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))],
            "session": ["stringValue": String(report.sessionTitle.prefix(60))],
            "sport": ["stringValue": report.sport],
            "duration": ["integerValue": String(Int(report.duration))],
            "distance": ["integerValue": String(Int(report.distance))],
            "analysisVersion": ["integerValue": String(report.analysisVersion)],
            "runsDownwind": ["integerValue": String(report.runsDownwind)],
            "runsReaching": ["integerValue": String(report.runsReaching)],
            "runsUpwind": ["integerValue": String(report.runsUpwind)],
            "stretches": ["integerValue": String(report.stretches)],
            "flights": ["integerValue": String(report.flights)],
            "turns": ["integerValue": String(report.turns)],
            "falls": ["integerValue": String(report.falls)],
            "jumps": ["integerValue": String(report.jumps)],
            "foilingFraction": ["doubleValue": finite(report.foilingFraction)],
            "appVersion": ["stringValue": appVersion],
            "system": ["stringValue": system],
            "createdAt": ["stringValue": ISO8601DateFormatter().string(from: Date())],
        ]
        if let direction = report.windDirection, direction.isFinite {
            fields["windDirection"] = ["doubleValue": direction]
        }
        if let source = report.windSource {
            fields["windSource"] = ["stringValue": source]
        }
        if let recordingPath {
            fields["recordingPath"] = ["stringValue": recordingPath]
        }
        let contact = report.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contact.isEmpty {
            fields["contact"] = ["stringValue": String(contact.prefix(200))]
        }
        return fields
    }

    /// A NaN reaches `JSONSerialization` as an unencodable value and throws,
    /// which surfaces to the rider as a failure to send rather than as the
    /// division by zero it actually was.
    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    /// The session as an archive, for a rider who has asked to send it.
    ///
    /// Built on demand rather than held on the report, so a sheet that is
    /// opened, read and cancelled never encodes a track at all.
    static func recording(of session: Session) -> Data? {
        try? SessionArchive(session: session).encoded()
    }

    private static func upload(_ archive: Data, named name: String) async -> String? {
        let objectName = "feedback/\(name).openwater"
        guard let encoded = objectName.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string:
                "https://firebasestorage.googleapis.com/v0/b/\(SpotGuideStore.storageBucket)/o?uploadType=media&name=\(encoded)")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = archive
        guard let (_, response) = try? await URLSession.shared.upload(for: request, from: archive),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return objectName
    }

    /// Exposed for `SessionFeedbackTests`, which holds this to the filename
    /// pattern the deployed Storage rule matches.
    static func testIdentifier() -> String { identifier() }

    /// A random name. Deliberately not derived from the session or the
    /// device: two reports from one rider should not be linkable by their
    /// identifiers alone.
    ///
    /// Twenty lowercase hex characters, because the Storage rule matches
    /// `^[a-f0-9]{20}\.openwater$` — a UUID's own dashes and uppercase would
    /// be refused.
    private static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20).description
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    @MainActor
    private static var systemVersion: String {
        "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)"
    }
}
