import SwiftUI

/// The nearby sheet, rebuilt from nothing.
///
/// The previous panel was fixed three times and a rider still saw the list
/// flicker when it slid, so it has been deleted and is being rebuilt one
/// moving part at a time — each phase tested on a real phone before the next
/// is added. Whichever phase brings the flicker back is the cause, by
/// construction.
///
/// - Phase 1: nothing moves. An opaque sheet fixed over the live map, a
///   plain scroll of plain rows. **Tested clean on the phone.**
/// - **Phase 2 (this one): the slide.** Three detents, and one way to move
///   between them: a drag on the grab bar. The list keeps its own scroll at
///   every height, and because the two gestures live on different views they
///   cannot fight — the fight was the old panel's disease. The height is
///   driven directly, which is the obvious code the old panel avoided; what
///   made direct height-driving churn back then was a lazy stack realizing
///   rows per frame and `AsyncImage` restarting per rebuild, and both of
///   those are gone by construction — the stack is plain and the thumbnails
///   are cached.
/// - Phase 3: drags on the content, and pull-past-the-top to collapse.
/// - Phase 4: Favorites and Destinations return.
struct SpotsSheet<Header: View, Content: View>: View {

    let size: CGSize
    /// Pinned between the grab bar and the list — the mode switch lives
    /// here, because a control that scrolls away with the thing it switches
    /// is not a control.
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    enum Detent: CaseIterable {
        case minimized, peek, half, full

        /// Screen fraction — except `minimized`, which is "the grab bar and
        /// nothing else" and is resolved in points, because the bar does not
        /// scale with the screen.
        var fraction: CGFloat {
            switch self {
            case .minimized: 0
            case .peek: 0.32
            case .half: 0.58
            case .full: 0.92
            }
        }
    }

    @State private var detent: Detent = .peek

    /// The live drag, in a `@GestureState` so it resets however the gesture
    /// dies. A cancelled drag — a call, a system gesture, anything stealing
    /// the touches — never runs `onEnded`, and the old panel's plain `@State`
    /// kept its last value and parked the sheet between detents. The reset
    /// transaction makes a cancelled drag glide home instead of snapping.
    @GestureState(resetTransaction: Transaction(animation: .snappy))
    private var drag: CGFloat = 0

    private func height(for detent: Detent) -> CGFloat {
        // Minimized is the grab bar and the header clear of the floating tab
        // bar — the mode switch stays reachable, the map gets everything
        // else. Everything else scales with the screen, never below that.
        max(tabBarHeight + 84, size.height * detent.fraction)
    }

    var body: some View {
        let live = min(height(for: .full),
                       max(height(for: .minimized), height(for: detent) - drag))
        VStack(spacing: 0) {
            grabBar
            header

            ScrollView {
                VStack(spacing: 0) {
                    content
                }
                .padding(.bottom, tabBarHeight + 12)
            }
        }
        .frame(height: live, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 6, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// The one handle that moves the sheet, generous enough to hit — with
    /// the chevron beside it doing the same job without a gesture at all,
    /// since a drag you have to discover is not a control.
    private var grabBar: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Button {
                    withAnimation(.snappy) {
                        detent = detent == .minimized ? .half : .minimized
                    }
                } label: {
                    Image(systemName: detent == .minimized ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 28)
                        .background(Color(.systemGray5), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 14)
                .accessibilityLabel(detent == .minimized ? "Expand nearby" : "Minimize nearby")
            }
            .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        // Global space, and this is load-bearing. A `DragGesture` measures in
        // the attached view's own space by default, and the grab bar *moves*
        // as the sheet resizes — so a stationary finger's position gets
        // re-read against a view that just slid under it, and the sheet's own
        // motion feeds back into the translation. That is jitter under the
        // thumb, and it is much worse at a real screen's 120 Hz than under
        // synthetic test touches, which is exactly the shape of a bug that
        // glitches on the phone and films clean on the simulator. Global
        // coordinates measure the finger against the screen, which does not
        // move.
        DragGesture(coordinateSpace: .global)
            .updating($drag) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                // The projected end of the flick decides, so a fast flick
                // crosses detents without stopping at each one.
                let projected = height(for: detent) - value.predictedEndTranslation.height
                let nearest = Detent.allCases.min {
                    abs(height(for: $0) - projected) < abs(height(for: $1) - projected)
                } ?? .peek
                withAnimation(.snappy) { detent = nearest }
            }
    }
}
