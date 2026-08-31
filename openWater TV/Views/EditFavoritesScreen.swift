import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Choosing which spots live on the board.
///
/// The phone stars a spot from the map, by tapping the pin you are already
/// looking at. There is no map gesture on a remote and no keyboard worth
/// typing a spot name on, so this drills instead: country, then region, then
/// the launches in it. Three presses to a spot, and the list at each level is
/// short enough to cross with a thumb.
///
/// The list is the TV's own. Favourites on the phone are `UserDefaults` with no
/// sync behind them, and giving a shipped app an iCloud container to solve a
/// once-per-household setup would be a poor trade — so this writes the same
/// keys through the same `toggleFavorite`, in this app's own defaults.
struct EditFavoritesScreen: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(\.dismiss) private var dismiss

    @State private var country: GuideRegion?

    var body: some View {
        NavigationStack {
            Group {
                if let country {
                    SpotPicker(title: country.name, spots: guide.spots(inCountry: country))
                } else {
                    countryList
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var countryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Where do you sail?")
                    .font(.system(size: 52, weight: .bold))
                    .padding(.bottom, 12)

                // Somebody's own country is the one they want, and it is rarely
                // the first alphabetically — so the ones carrying the most
                // launches come first, which in practice puts it near the top.
                ForEach(guide.countries.sorted { $0.spotCount > $1.spotCount }) { region in
                    Button { country = region } label: {
                        HStack {
                            Text(region.name).font(.system(size: 34))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(region.spotCount)")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }
}

/// The launches in one country, each a toggle.
///
/// Starring here does not leave the list. Setting the board up means picking
/// four or five in a row, and a screen that popped back after each one would
/// make somebody drill in five times.
private struct SpotPicker: View {

    let title: String
    let spots: [GuideSpot]

    @Environment(SpotGuideStore.self) private var guide

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.system(size: 52, weight: .bold))
                    .padding(.bottom, 12)

                ForEach(spots.sorted { $0.name < $1.name }) { spot in
                    let starred = guide.favoriteIds.contains(spot.spotId)
                    Button { guide.toggleFavorite(spot.spotId) } label: {
                        HStack(spacing: 24) {
                            Image(systemName: starred ? "star.fill" : "star")
                                .font(.system(size: 28))
                                .foregroundStyle(starred ? Color.accentColor : .secondary)
                                .frame(width: 44)
                            Text(spot.name).font(.system(size: 32))
                                .foregroundStyle(.white)
                            Spacer()
                            if let region = spot.adminRegion {
                                Text(region)
                                    .font(.system(size: 24))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }
}
