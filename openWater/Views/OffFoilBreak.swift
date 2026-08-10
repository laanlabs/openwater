import SwiftUI

/// The swim between two runs.
///
/// Runs already break at a touchdown, so the gap was implied by two rows
/// being adjacent and nothing else — which made a five-second touch-and-go
/// and a two-minute walk back upwind look identical. Saying it out loud is
/// what turns a list of runs into an account of the session.
///
/// Drawn as a break in the list rather than as a row: it is the absence of
/// riding, and it should not read as another thing the rider did.
struct OffFoilBreak: View {
    let seconds: TimeInterval

    private var text: String {
        let whole = Int(seconds.rounded())
        return whole < 60
            ? "off foil \(whole)s"
            : "off foil \(whole / 60):\(String(format: "%02d", whole % 60))"
    }

    var body: some View {
        HStack(spacing: 8) {
            line
            Label(text, systemImage: "figure.pool.swim")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            line
        }
        .padding(.vertical, 2)
        .accessibilityLabel("Off the foil for \(text)")
    }

    private var line: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
    }
}
