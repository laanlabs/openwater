import Foundation
import UIKit

/// Submitting spot suggestions and corrections — the same pipeline the
/// website uses, byte for byte.
///
/// The security model is the website's, worth restating because it is what
/// makes an unauthenticated client safe: Firestore accepts *create only* into
/// `spotSuggestions`, every field bounded by the rules; Storage accepts
/// create-only images under `suggestions/`, capped at 8 MB, never publicly
/// readable. Nothing submitted is visible to anyone until it has been
/// reviewed with owner credentials. The app cannot read, list, edit or delete
/// a suggestion — including its own.
enum SpotSuggestionClient {

    struct Submission {
        var type: String                 // "new-spot" | "correction"
        var kind: String = ""            // "" | camera | wind | photo | correction
        var spotId: String = ""
        var name: String = ""
        var location: String = ""
        var activities: String = ""
        var spotType: String = ""        // "launch" when points are present
        var points: String = ""          // JSON [[lat, lng]]
        var details: String = ""
        var links: String = ""
        var contact: String = ""
    }

    enum SubmissionError: LocalizedError {
        case photoUpload
        case save

        var errorDescription: String? {
            switch self {
            case .photoUpload: "A photo upload failed — try again, or submit without photos."
            case .save: "Something went wrong saving your submission — please try again in a minute."
            }
        }
    }

    /// Upload the photos, then create the document — the site's order, so a
    /// failed photo never leaves a photo-less record claiming otherwise.
    static func submit(_ submission: Submission, photos: [Data]) async throws {
        let id = suggestionId()

        var imagePaths: [String] = []
        for (index, jpeg) in photos.enumerated() {
            // First photo takes the bare id, extras are numbered — both
            // shapes fit the storage rules' filename pattern.
            let name = index == 0 ? id : "\(id)-\(index + 1)"
            guard let path = await uploadImage(named: name, jpeg: jpeg) else {
                throw SubmissionError.photoUpload
            }
            imagePaths.append(path)
        }

        var fields: [String: [String: String]] = [:]
        let values: [(String, String)] = [
            ("type", submission.type),
            ("kind", String(submission.kind.prefix(40))),
            ("spotId", String(submission.spotId.prefix(20))),
            ("name", clean(submission.name, 200)),
            ("location", clean(submission.location, 500)),
            ("activities", clean(submission.activities, 300)),
            ("spotType", String(submission.spotType.prefix(12))),
            ("points", String(submission.points.prefix(600))),
            ("details", String(submission.details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))),
            ("links", String(submission.links.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))),
            ("contact", clean(submission.contact, 200)),
            ("imagePaths", String(imagePaths.joined(separator: ",").prefix(400))),
            ("createdAt", ISO8601DateFormatter().string(from: Date())),
        ]
        for (key, value) in values where !value.isEmpty {
            fields[key] = ["stringValue": value]
        }

        var request = URLRequest(url: URL(string:
            "\(SpotGuideStore.firestoreBase)/spotSuggestions?documentId=\(id)&key=\(SpotGuideStore.apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { throw SubmissionError.save }
    }

    /// 16 random bytes, base64url — the site's `crypto.randomBytes(16)
    /// .toString("base64url")`, and the shape the storage filename rules
    /// expect.
    private static func suggestionId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func uploadImage(named name: String, jpeg: Data) async -> String? {
        let objectName = "suggestions/\(name).jpg"
        guard let encoded = objectName.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string:
                "https://firebasestorage.googleapis.com/v0/b/\(SpotGuideStore.storageBucket)/o?uploadType=media&name=\(encoded)")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return objectName
    }

    private static func clean(_ value: String, _ max: Int) -> String {
        String(value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(max))
    }

    /// JPEG under the storage cap, downscaling if the camera was ambitious.
    /// Modern phone photos at full resolution routinely clear 8 MB; the guide
    /// needs "what does the launch look like", not print quality.
    static func jpegForUpload(_ image: UIImage) -> Data? {
        var current = image
        for _ in 0..<4 {
            if let data = current.jpegData(compressionQuality: 0.8),
               data.count < 8 * 1024 * 1024 {
                return data
            }
            let scaled = CGSize(width: current.size.width * 0.7,
                                height: current.size.height * 0.7)
            let renderer = UIGraphicsImageRenderer(size: scaled)
            current = renderer.image { _ in
                current.draw(in: CGRect(origin: .zero, size: scaled))
            }
        }
        return current.jpegData(compressionQuality: 0.5)
    }
}
