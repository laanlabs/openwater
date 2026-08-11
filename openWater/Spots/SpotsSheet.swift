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
struct SpotsSheet<Content: View>: View {

    let size: CGSize
    @ViewBuilder var content: Content

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    enum Detent: CaseIterable {
        case peek, half, full

        var fraction: CGFloat {
            switch self {
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
        size.height * detent.fraction
    }

    var body: some View {
        let live = min(height(for: .full),
                       max(height(for: .peek), height(for: detent) - drag))
        VStack(spacing: 0) {
            grabBar

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

    /// The one handle that moves the sheet, generous enough to hit.
    private var grabBar: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Rectangle())
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
