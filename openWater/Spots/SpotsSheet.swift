import SwiftUI

/// The nearby sheet, rebuilt from nothing.
///
/// The previous panel was fixed three times and a rider still saw the list
/// flicker when it slid, so it has been deleted and is being rebuilt one
/// moving part at a time — each phase tested on a real phone before the next
/// is added. Whichever phase brings the flicker back is the cause, by
/// construction.
///
/// - **Phase 1 (this one): nothing moves.** An opaque sheet fixed at 55% of
///   the screen over the live map, a plain `ScrollView` with a plain
///   `VStack` of rows — not even lazy — and scrolling as the only
///   interaction. If this flickers, the problem was never the panel: it is
///   the rows, the scroll, or compositing over the map.
/// - Phase 2: the slide — detents, a drag on the grab bar only.
/// - Phase 3: drags on the content, and pull-past-the-top to collapse.
/// - Phase 4: Favorites and Destinations return.
struct SpotsSheet<Content: View>: View {

    let size: CGSize
    @ViewBuilder var content: Content

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 0) {
                    content
                }
                .padding(.bottom, tabBarHeight + 12)
            }
        }
        .frame(height: size.height * 0.55, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 6, y: -2)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
