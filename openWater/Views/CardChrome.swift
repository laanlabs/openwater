import SwiftUI

/// The small grey label above a block of numbers.
///
/// This existed thirteen times as a copy-pasted
/// `.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)`, which was
/// fine while every one of them lived on the same screen and drifted the
/// moment they did not. The Analysis screens need a single answer.
struct SectionHeader: View {

    let title: String

    /// Optional trailing content — a wind badge, an ⓘ, a count.
    var trailing: AnyView?

    init(_ title: String) {
        self.title = title
        self.trailing = nil
    }

    init(_ title: String, @ViewBuilder trailing: () -> some View) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let trailing {
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

extension View {

    /// The card a block of content sits in.
    ///
    /// Summary used to mix chromed and un-chromed cards — the header and
    /// headline numbers drew their own rounded background while Foiling,
    /// Downwind, Turns, Angles, Upwind and Quality relied on whatever the
    /// parent happened to be. On one grouped background that reads as an
    /// inconsistency rather than a hierarchy, and it is why moving those cards
    /// to their own screens needed a single definition first.
    func cardChrome(padding: CGFloat = 14, cornerRadius: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
