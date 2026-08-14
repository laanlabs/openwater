import SwiftUI
import WeatherKit

/// The " Weather" mark with Apple's legal page behind it.
///
/// WeatherKit's terms require both halves wherever its data is shown: the
/// trademark *and* a working link to the legal attribution page — App Review
/// rejects for either one missing (Guideline 5.2.5). The live URL comes from
/// the attribution API, but that is a network call that can fail on exactly
/// the screens that already managed to show weather; Apple's published
/// address stands in until it answers, so the link is never absent.
struct AppleWeatherAttribution: View {

    /// Apple's published legal page, shown until the API's answer arrives.
    static let legalPage = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    /// An explicit "Legal" word beside the mark — the convention Apple's own
    /// maps use — where the row has room for it. The bare mark stays the
    /// default for tight corners.
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
                Link("Legal", destination: legal)
                    .foregroundStyle(.secondary)
                    .underline()
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
