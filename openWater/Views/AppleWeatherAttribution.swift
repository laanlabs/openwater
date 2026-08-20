import SwiftUI
import WeatherKit

/// The " Weather" mark with Apple's legal page behind it.
///
/// WeatherKit's terms ask for both halves wherever its data is shown: the
/// trademark *and* a working link to the legal attribution page, and App
/// Review has rejected for either one missing (Guideline 5.2.5). The live URL
/// comes from the attribution API, but that is a network call that can fail on
/// exactly the screens that already managed to show weather; Apple's published
/// address stands in until it answers, so the link is never absent.
///
/// Where it actually appears is Settings and the session rows. The cards on
/// the conditions sheet carry no attribution at all — a product decision, made
/// deliberately, on the grounds that Settings states the arrangement in one
/// place. Worth knowing before the next submission: it is the part of this
/// that Apple's terms do not obviously allow, and if a build comes back citing
/// 5.2.5, this is the first thing to put back.
struct AppleWeatherAttribution: View {

    /// Apple's published legal page, shown until the API's answer arrives.
    static let legalPage = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    /// An explicit "Legal" word beside the mark — the convention Apple's own
    /// maps use — where the row has room for it. Both callers that are left
    /// ask for it; the bare mark stays the default for tight corners.
    var showsLegalLabel = false

    /// Plain-language words before the mark ("Weather data provided by"),
    /// where the bare trademark would read as decoration. The mark itself is
    /// never reworded — " Weather" is the trademark Apple requires, and the
    /// consumer-facing brand; "WeatherKit" is only the API's name and does
    /// not belong in UI.
    var prefix: String?

    @State private var legal = AppleWeatherAttribution.legalPage

    var body: some View {
        HStack(spacing: 6) {
            if let prefix {
                Text(prefix)
                    .foregroundStyle(.secondary)
            }
            // U+F8FF is the Apple logo, written as an escape because the
            // literal glyph is invisible in most editors — it silently went
            // missing from this codebase once already, leaving the mark as a
            // bare "Weather".
            Link("\u{F8FF} Weather", destination: legal)
            if showsLegalLabel {
                // The underline rides on the label's own Text rather than on
                // the Link, because a button style restyles the label it is
                // handed and an underline applied to the Link is lost with it.
                // Callers that share a row have to set a style — see
                // WeatherStatusView — and the underline is the whole signal
                // that this grey word is a link.
                Link(destination: legal) { Text("Legal").underline() }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .task {
            if let url = try? await WeatherService.shared.attribution.legalPageURL {
                legal = url
            }
        }
    }
}
