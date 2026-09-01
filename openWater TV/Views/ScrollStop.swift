import SwiftUI

/// A block of read-only content the remote can stop on.
///
/// This exists because of the single sharpest difference between scrolling on
/// a phone and scrolling on a television: there is no drag. A tvOS
/// `ScrollView` moves for exactly one reason — to keep the *focused* view on
/// screen — so a column with nothing focusable in it does not scroll at all,
/// however far past the bottom of the screen it runs. Text is not focusable.
/// A forecast strip is not focusable. A list of anemometer readings is not
/// focusable. So the page reads as broken: the remote does nothing, and the
/// rows below the fold may as well not exist.
///
/// Worse than nothing happening is what happens when there *is* one focusable
/// thing far down the page — a picker, a button. The focus engine finds it on
/// appearance and scrolls straight to it, so the screen opens already past the
/// headline it was opened to show.
///
/// Wrapping each block in one of these gives the D-pad somewhere to land at
/// every step down the page, which is what makes the scroll follow. The focus
/// ring is deliberately quiet — a faint wash rather than tvOS's card lift —
/// because these are things to read, not things to press, and a block that
/// jumps under the eye reads as a button that failed to do anything.
struct ScrollStop<Content: View>: View {

    @ViewBuilder var content: Content

    @FocusState private var isFocused: Bool

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            // Full width, so the wash is a band across the column rather than
            // a box drawn round whatever happens to be the longest line in
            // this particular block.
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isFocused ? Color.white.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 20))
            .contentShape(RoundedRectangle(cornerRadius: 20))
            .focusable()
            .focused($isFocused)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}
