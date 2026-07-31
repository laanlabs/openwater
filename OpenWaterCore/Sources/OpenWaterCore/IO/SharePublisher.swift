import Foundation
import os

/// Where a shared session goes and where the link points.
///
/// Split out from the publisher so the bucket is stated in one place. Two URLs
/// come out of a share and they are not the same thing: the *file* URL is where
/// the JSON physically lives in Firebase Storage, and the *link* URL is the
/// human-facing page on openwater.app that fetches it and draws the map. Only
/// the second one is ever shown to a rider.
public struct ShareDestination: Hashable, Sendable {

    /// Firebase Storage bucket, e.g. `openwaterapp-2e0f7.firebasestorage.app`.
    public var bucket: String

    /// Folder inside the bucket. Matched by the storage rules, so changing it
    /// here means changing them too.
    public var folder: String

    /// Site that renders the share page.
    public var site: URL

    public init(bucket: String, folder: String = "shares", site: URL) {
        self.bucket = bucket
        self.folder = folder
        self.site = site
    }

    public static let openWater = ShareDestination(
        bucket: "openwaterapp-2e0f7.firebasestorage.app",
        site: URL(string: "https://openwater.app")!
    )

    /// Object path within the bucket.
    public func objectPath(for code: String) -> String {
        "\(folder)/\(code).json"
    }

    /// Where the file is written and read. Firebase's REST API wants the object
    /// path percent-encoded *as a query value* on upload and *as a path
    /// component* on read, which is why the two are built separately rather
    /// than sharing one string.
    func uploadURL(for code: String) -> URL? {
        var components = URLComponents(string: "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o")
        components?.queryItems = [
            URLQueryItem(name: "uploadType", value: "media"),
            URLQueryItem(name: "name", value: objectPath(for: code)),
        ]
        return components?.url
    }

    public func fileURL(for code: String) -> URL? {
        let escaped = objectPath(for: code)
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? objectPath(for: code)
        return URL(string: "https://firebasestorage.googleapis.com/v0/b/\(bucket)/o/\(escaped)?alt=media")
    }

    /// The link a rider actually sends to someone.
    public func linkURL(for code: String) -> URL {
        site.appendingPathComponent("s").appendingPathComponent(code)
    }
}

/// A published share.
public struct SharedLink: Hashable, Sendable, Codable {
    public var code: String
    public var url: URL
    public var createdAt: Date

    public init(code: String, url: URL, createdAt: Date = Date()) {
        self.code = code
        self.url = url
        self.createdAt = createdAt
    }
}

public enum ShareError: LocalizedError, Sendable {
    case tooLarge(Int)
    case badConfiguration
    case server(status: Int, message: String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            "This session is too big to share (\(bytes / 1024) KB)."
        case .badConfiguration:
            "The share destination is not configured correctly."
        case .server(let status, let message):
            message.isEmpty ? "The share service refused the upload (\(status))." : message
        case .unexpectedResponse:
            "The share service sent back something unexpected."
        }
    }
}

/// Uploads a `ShareSnapshot` and hands back a link.
///
/// Deliberately a plain `URLSession` call against the Firebase Storage REST
/// endpoint rather than the Firebase SDK. The whole feature is one anonymous
/// PUT of a small JSON file; pulling in a dependency that brings its own
/// analytics, background threads and app-lifecycle hooks to achieve that would
/// cost more than it gives, and openWater's promise is that it works without an
/// account.
///
/// There is no authentication, which is a real trade-off rather than an
/// oversight. The security of a share rests entirely on the code being
/// unguessable — see `ShareSnapshot.makeCode()` — and the storage rules cap
/// what an anonymous caller can do: create only, one small JSON file, at a path
/// that has to look like a generated code. A share cannot be overwritten or
/// deleted once written, so a link that has been sent out cannot be swapped for
/// different content behind the recipient's back.
public struct SharePublisher: Sendable {

    private static let logger = Logger(
        subsystem: "com.laan.labs.openWater", category: "Share"
    )

    public var destination: ShareDestination

    /// Refuse anything larger. The storage rules enforce the same ceiling, and
    /// finding out locally gives a better message than a 403.
    public var maximumBytes: Int

    public init(destination: ShareDestination = .openWater, maximumBytes: Int = 512 * 1024) {
        self.destination = destination
        self.maximumBytes = maximumBytes
    }

    /// Publish a snapshot under a freshly generated code.
    @discardableResult
    public func publish(
        _ snapshot: ShareSnapshot,
        code: String = ShareSnapshot.makeCode(),
        using urlSession: URLSession = .shared
    ) async throws -> SharedLink {
        let body = try snapshot.encoded()
        guard body.count <= maximumBytes else { throw ShareError.tooLarge(body.count) }
        guard let endpoint = destination.uploadURL(for: code) else { throw ShareError.badConfiguration }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A beach is the worst network there is. Fail in twenty seconds with a
        // message rather than leaving the rider staring at a spinner.
        request.timeoutInterval = 20

        let (data, response) = try await urlSession.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw ShareError.unexpectedResponse }

        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data)
            Self.logger.error("share upload failed: \(http.statusCode) \(message, privacy: .public)")
            throw ShareError.server(status: http.statusCode, message: message)
        }

        Self.logger.info("shared session as \(code, privacy: .public) (\(body.count) bytes)")
        return SharedLink(code: code, url: destination.linkURL(for: code))
    }

    /// Pull the human-readable message out of a Firebase error body.
    static func errorMessage(from data: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message ?? ""
    }
}
