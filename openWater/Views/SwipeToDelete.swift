import SwiftUI

/// Swipe a card left to reveal Delete.
///
/// `List` gives this away for free, but the sessions list is a `LazyVStack` of
/// cards — it has a map preview, a title block and a stat row, and forcing that
/// into a list row costs the layout more than the gesture is worth. So the
/// gesture is built here instead.
///
/// The whole difficulty is telling a delete from a scroll. A card is 300 points
/// tall in a vertical scroll view, and a drag that starts even slightly off
/// horizontal is almost always somebody scrolling. So the gesture only takes
/// over once the movement is decisively sideways, and gives the drag back to
/// the scroll view otherwise.
struct SwipeToDelete: ViewModifier {

    let onDelete: () -> Void

    /// How far the card has moved, and whether this drag has been claimed.
    @State private var offset: CGFloat = 0
    @State private var claimed: Bool?

    /// Width of the revealed button. Wide enough to hit without looking.
    private let revealWidth: CGFloat = 92

    /// Past this the swipe deletes on release rather than resting open — the
    /// shortcut for somebody who knows what they are doing.
    private let commitWidth: CGFloat = 220

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            Button(action: delete) {
                Image(systemName: "trash.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
            .opacity(offset < -4 ? 1 : 0)
            .accessibilityLabel("Delete session")

            content
                .offset(x: offset)
        }
        .animation(.snappy(duration: 0.22), value: offset)
        // Simultaneous, not exclusive. The card is a navigation link and the
        // list is a scroll view, and both want the drag; taking it outright
        // means a swipe opens the session instead, and taking it too eagerly
        // means the list stops scrolling. Running alongside them and acting
        // only on clearly horizontal movement leaves taps and scrolls intact.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    if claimed == nil {
                        // Decided once per drag, from its shape: clearly
                        // sideways is a swipe, anything else belongs to the
                        // scroll view and is never reconsidered.
                        claimed = abs(value.translation.width) > abs(value.translation.height) * 1.6
                    }
                    guard claimed == true else { return }
                    // Rightward drags close an open card and do nothing else;
                    // there is no action on that side to reveal.
                    offset = min(0, value.translation.width + (offset <= -revealWidth ? -revealWidth : 0))
                }
                .onEnded { value in
                    defer { claimed = nil }
                    guard claimed == true else { return }
                    if value.translation.width < -commitWidth {
                        offset = 0
                        delete()
                    } else {
                        offset = offset < -revealWidth / 2 ? -revealWidth : 0
                    }
                }
        )
    }

    private func delete() {
        offset = 0
        onDelete()
    }
}

extension View {
    func swipeToDelete(onDelete: @escaping () -> Void) -> some View {
        modifier(SwipeToDelete(onDelete: onDelete))
    }
}
