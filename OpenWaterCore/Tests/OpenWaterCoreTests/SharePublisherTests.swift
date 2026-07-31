import Foundation
import Testing
@testable import OpenWaterCore

/// Intercepts uploads so the request shape can be checked without touching the
/// network. Firebase's REST API is unforgiving about how the object name is
/// encoded, and a mistake there is invisible until a real share 404s.
final class StubProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        status = 200
        responseBody = Data("{}".utf8)
        lastRequest = nil
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // `httpBody` is nil for an upload task; the body arrives as a stream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite("Share publisher", .serialized)
struct SharePublisherTests {

    private func snapshot() -> ShareSnapshot {
        ShareSnapshot(
            title: "Test",
            sport: "Wingfoil",
            sportSymbol: "wind",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            distance: 12_000,
            duration: 3600,
            movingTime: 3000,
            maxSpeed: 14,
            averageMovingSpeed: 8,
            categories: [],
            foilingFraction: 0.5,
            flightCount: 12,
            runCount: 20,
            points: [[-122.34, 37.845, 8.1]],
            speedCeiling: 14
        )
    }

    @Test("The upload lands at the object path the storage rules expect")
    func uploadURL() async throws {
        StubProtocol.reset()
        let publisher = SharePublisher()
        let link = try await publisher.publish(
            snapshot(), code: "abcDEF012345678901xyz-",
            using: StubProtocol.makeSession()
        )

        let request = try #require(StubProtocol.lastRequest)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(url.host == "firebasestorage.googleapis.com")
        #expect(url.path == "/v0/b/openwaterapp-2e0f7.firebasestorage.app/o")
        // The slash has to survive as part of the *value*, not become a path
        // separator — otherwise the file lands at the bucket root and the rule
        // matching `shares/{code}` never fires.
        #expect(components.queryItems?.first { $0.name == "name" }?.value == "shares/abcDEF012345678901xyz-.json")
        #expect(link.url.absoluteString == "https://openwaterapp.com/s/abcDEF012345678901xyz-")
    }

    @Test("The body is the snapshot, and nothing but the snapshot")
    func uploadBody() async throws {
        StubProtocol.reset()
        _ = try await SharePublisher().publish(snapshot(), using: StubProtocol.makeSession())

        let body = try #require(StubProtocol.lastBody)
        let decoded = try ShareSnapshot.decode(body)
        #expect(decoded.title == "Test")
        #expect(decoded.points.count == 1)
    }

    @Test("A refusal from the server surfaces its own message")
    func serverError() async {
        StubProtocol.reset()
        StubProtocol.status = 403
        StubProtocol.responseBody = Data(#"{"error":{"code":403,"message":"Permission denied."}}"#.utf8)

        await #expect(throws: ShareError.self) {
            _ = try await SharePublisher().publish(snapshot(), using: StubProtocol.makeSession())
        }
    }

    @Test("Oversized payloads are refused before they leave the device")
    func tooLarge() async {
        StubProtocol.reset()
        var big = snapshot()
        big.points = Array(repeating: [-122.34, 37.845, 8.1], count: 50_000)

        await #expect(throws: ShareError.self) {
            _ = try await SharePublisher(maximumBytes: 1024)
                .publish(big, using: StubProtocol.makeSession())
        }
        #expect(StubProtocol.lastRequest == nil, "an oversized share was still uploaded")
    }

    @Test("The read URL escapes the folder separator")
    func fileURL() throws {
        let url = try #require(ShareDestination.openWater.fileURL(for: "code123"))
        #expect(url.absoluteString.contains("o/shares%2Fcode123%2Ejson"))
        #expect(url.absoluteString.hasSuffix("?alt=media"))
    }
}
