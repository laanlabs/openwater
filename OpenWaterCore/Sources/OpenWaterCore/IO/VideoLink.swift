import Foundation

/// Recognises the video links the guide's cams use — currently the one
/// provider whose links can be played inside the app instead of bounced
/// out to another one.
public enum VideoLink {

    /// The YouTube video id, from any of the shapes a cam link takes:
    /// `watch?v=`, `youtu.be/`, `/live/`, `/embed/`, `/shorts/`, with or
    /// without tracking noise in the query. `nil` for anything that is not
    /// unmistakably a single YouTube video — a channel page, a playlist, a
    /// different site — because a guess here would embed a broken player
    /// over a link that worked.
    public static func youTubeID(from url: URL) -> String? {
        var host = url.host?.lowercased() ?? ""
        for prefix in ["www.", "m."] where host.hasPrefix(prefix) {
            host.removeFirst(prefix.count)
        }
        let parts = url.path.split(separator: "/").map(String.init)

        if host == "youtu.be" {
            return valid(parts.first)
        }
        guard host == "youtube.com" || host == "youtube-nocookie.com" else { return nil }
        switch parts.first {
        case "watch":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            return valid(query?.first { $0.name == "v" }?.value)
        case "embed", "live", "shorts", "v":
            return valid(parts.count > 1 ? parts[1] : nil)
        default:
            return nil
        }
    }

    /// Eleven characters of the id alphabet — the shape every real id has.
    private static func valid(_ id: String?) -> String? {
        guard let id, id.count == 11,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return id
    }
}
