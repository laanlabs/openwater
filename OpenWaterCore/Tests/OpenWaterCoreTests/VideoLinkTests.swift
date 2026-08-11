import Foundation
import Testing
@testable import OpenWaterCore

/// The link shapes cams actually arrive in — and the ones that must not
/// be mistaken for a video.
@Suite("Video links")
struct VideoLinkTests {

    private func id(_ text: String) -> String? {
        URL(string: text).flatMap { VideoLink.youTubeID(from: $0) }
    }

    @Test("Every shape of a real video link yields its id")
    func realLinks() {
        #expect(id("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://youtube.com/watch?v=dQw4w9WgXcQ&t=42s&si=abc") == "dQw4w9WgXcQ")
        #expect(id("https://youtu.be/dQw4w9WgXcQ?si=tracking") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube.com/live/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://m.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(id("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
    }

    @Test("Pages that are not one video stay nil")
    func notVideos() {
        #expect(id("https://www.youtube.com/@somechannel") == nil)
        #expect(id("https://www.youtube.com/channel/UCabcdef") == nil)
        #expect(id("https://www.youtube.com/playlist?list=PL123") == nil)
        #expect(id("https://www.youtube.com/watch") == nil)
        #expect(id("https://vimeo.com/123456789") == nil)
        #expect(id("https://www.surfline.com/surf-report/spot/5842") == nil)
        // An id-shaped string on the wrong host is still not a video.
        #expect(id("https://notyoutube.com/watch?v=dQw4w9WgXcQ") == nil)
    }

    @Test("Malformed ids are refused rather than embedded broken")
    func malformedIDs() {
        #expect(id("https://youtu.be/short") == nil)
        #expect(id("https://www.youtube.com/watch?v=waytoolongtobeanid") == nil)
        #expect(id("https://www.youtube.com/watch?v=has%20space1") == nil)
    }
}
