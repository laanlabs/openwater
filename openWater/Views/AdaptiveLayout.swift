import SwiftUI

/// Keeps a scrolling page's content at a readable width when the window is
/// wider than a phone.
///
/// Every page in this app grew up owning the full width of an iPhone, and on
/// an iPad that habit stretches a statistics card to the width of a dinner
/// tray: the label at one end, its number at the other, and a hand-span of
/// nothing between them. The fix is not a second layout — it is margins. The
/// content keeps the column width it was designed at, centred, and the page's
/// background still runs edge to edge behind it.
///
/// Done with `contentMargins` rather than `frame(maxWidth:)` on the list
/// itself, because a narrowed `List` drags its background, its scroll
/// indicators and its swipe actions in with it — the page turns into a strip
/// with dead gutters either side. Margins inset only the rows; the scroll
/// view, its indicators and its background stay the full width of the window.
///
/// Maps and other full-bleed screens never use this: an 11-inch chart of the
/// bay is the one thing an iPad does better than a phone.
struct ReadableContentColumn: ViewModifier {

    /// The widest a column of cards and controls is allowed to run. 700 keeps
    /// an iPad column noticeably wider than a phone — these cards carry maps
    /// and charts, not prose — while pulling labels and their numbers back
    /// within a glance of each other.
    var maxWidth: CGFloat = 700

    @State private var inset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                inset = max(0, (width - maxWidth) / 2)
            }
    }
}

extension View {
    /// Centre this scrolling container's content in a column of at most
    /// `maxWidth` points. Attach to the `List`, `Form` or `ScrollView` itself.
    func readableContentColumn(maxWidth: CGFloat = 700) -> some View {
        modifier(ReadableContentColumn(maxWidth: maxWidth))
    }
}

// MARK: - Full-screen sheets

/// A sheet on a phone, a full-screen cover on anything regular-width.
///
/// `.sheet` with a `.large` detent *is* the full screen on an iPhone, so a
/// screen designed to own the display gets it for free. On an iPad the same
/// call quietly becomes a centred page sheet — detents are ignored in a
/// regular width — and a panel meant to replace the screen floats in the
/// middle of it instead. These wrappers pick the presentation that keeps the
/// original intent: full screen everywhere.
///
/// Both presentation modifiers stay attached and only the binding is gated.
/// An `if` on the size class here would swap the *content's* identity when a
/// Split View drag crosses the boundary, and every scroll position under this
/// modifier would reset with it.
private struct FullScreenSheet<Sheet: View>: ViewModifier {

    @Environment(\.horizontalSizeClass) private var width
    @Binding var isPresented: Bool
    @ViewBuilder var sheet: () -> Sheet

    func body(content: Content) -> some View {
        let regular = width == .regular
        content
            .sheet(isPresented: regular ? .constant(false) : $isPresented, content: sheet)
            .fullScreenCover(isPresented: regular ? $isPresented : .constant(false), content: sheet)
    }
}

private struct FullScreenItemSheet<Item: Identifiable, Sheet: View>: ViewModifier {

    @Environment(\.horizontalSizeClass) private var width
    @Binding var item: Item?
    @ViewBuilder var sheet: (Item) -> Sheet

    func body(content: Content) -> some View {
        let regular = width == .regular
        content
            .sheet(item: regular ? .constant(nil) : $item, content: sheet)
            .fullScreenCover(item: regular ? $item : .constant(nil), content: sheet)
    }
}

extension View {
    /// Present full screen on every device: a `.large` sheet where that
    /// already fills the display, a full-screen cover where it would not.
    func fullScreenSheet<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(FullScreenSheet(isPresented: isPresented, sheet: content))
    }

    /// The `item:` flavour of `fullScreenSheet(isPresented:content:)`.
    func fullScreenSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(FullScreenItemSheet(item: item, sheet: content))
    }
}
