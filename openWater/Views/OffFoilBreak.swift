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

    /// Picked out on the map, like a run. Time off the foil is part of the
    /// session and a rider tracking the whole of it should be able to point
    /// at this and be shown where it happened.
    var isSelected = false

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
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, isSelected ? 8 : 0)
                .padding(.vertical, isSelected ? 3 : 0)
                .background {
                    if isSelected {
                        Capsule().fill(Color(red: 0.45, green: 0.48, blue: 0.53))
                    }
                }
            line
        }
        // Room for a thumb: this is a control now, not only a caption.
        .padding(.vertical, 7)
        .accessibilityLabel("Off the foil for \(text)")
        .accessibilityAddTraits(.isButton)
    }

    private var line: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
    }
}
