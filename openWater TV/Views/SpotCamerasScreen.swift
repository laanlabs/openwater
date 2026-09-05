import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Every camera near one spot, on a page of its own.
///
/// These used to be a strip of thumbnails at the foot of the report — a
/// horizontal scroller inside a vertical one, which on a television means the
/// remote has to be pointed sideways at exactly the right row, and a cam past
/// the sixth was a cam nobody found. The cameras tab already knows how to lay
/// this out for a whole coast: a grid, playable first, and a map over it. So
/// a spot's cameras get the same grid, one press in from its report, with the
/// spot's name at the top so it is clear whose water this is.
///
/// The cards are `CamCard`s, so watching from here goes through exactly the
/// same resolving and the same covers as the cameras tab; the map is the
/// cameras tab's own `CamsMapScreen`. Nothing here decides how a camera opens.
struct SpotCamerasScreen: View {

    let cams: [SpotGuideStore.GuideResource]
    let placeName: String

    @State private var showsMap = false

    private let columns = [GridItem(.adaptive(minimum: 420), spacing: 40)]

    /// So the page opens on its own headline rather than on whichever card the
    /// focus engine finds first — which on a grid is one in the middle.
    @Namespace private var page

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                ScrollStop { header }
                    .prefersDefaultFocus(in: page)
                mapButton
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(cams) { CamCard(cam: $0) }
                }
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 60)
        }
        .focusScope(page)
        .background(Color.black.ignoresSafeArea())
        // Stated, not inherited — see `ConditionsScreen`. On a television set
        // to Light, `.primary` is black on this black page.
        .foregroundStyle(.white)
        .menuBackHint()
        .fullScreenCover(isPresented: $showsMap) {
            CamsMapScreen(cams: cams)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cameras near \(placeName)")
                .font(.system(size: 54, weight: .bold))
                .lineLimit(2)
            Text(playableCount > 0
                 ? "\(playableCount) of \(cams.count) play on this Apple TV. The rest hand off to your phone."
                 : "None of these play on this Apple TV — each one hands off to your phone.")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
    }

    private var playableCount: Int { cams.filter { $0.playback != nil }.count }

    /// The same words and the same place as the cameras tab, so the two
    /// screens teach each other.
    private var mapButton: some View {
        Button { showsMap = true } label: {
            Label("View on map", systemImage: "map")
                .font(.system(size: 26, weight: .medium))
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
        }
        .buttonStyle(.bordered)
    }
}
