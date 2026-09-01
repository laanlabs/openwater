import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Choosing which spots live on the board.
///
/// Three ways in, because three different people are looking at this screen.
///
/// **Type it.** Somebody who knows the name of their launch should not have to
/// find which country the guide filed it under. `searchable` puts tvOS's own
/// keyboard on the left and the matches on the right, with dictation for free
/// — which is the difference between typing "Napeague" on a television and
/// giving up. This is the way in the screen leads with, and the one the
/// original version was missing: it drilled country → spot and nothing else,
/// on the argument that there is no keyboard worth typing a spot name on. That
/// argument was written before the search screen on the map tab proved
/// otherwise.
///
/// **Take what is nearby.** A household setting this up is almost always
/// setting it up for the coast the map is already looking at, and the app
/// knows where that is. One section, the twelve nearest launches, no typing.
///
/// **Drill.** Kept for browsing: somebody planning a trip to a coast they have
/// never sailed wants a list of what is there, and that is a question no
/// search box answers.
///
/// The list is the TV's own. Favourites on the phone are `UserDefaults` with no
/// sync behind them, and giving a shipped app an iCloud container to solve a
/// once-per-household setup would be a poor trade — so this writes the same
/// keys through the same `toggleFavorite`, in this app's own defaults.
struct EditFavoritesScreen: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVLocation.self) private var location
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Bound so Menu can be answered a level at a time — see the exit handler
    /// below, and `ConditionsScreen` for why the stack cannot be left to do
    /// this itself inside a modal.
    @State private var path: [GuideRegion] = []

    var body: some View {
        // An opaque ground, for the reason `PlaceSearchScreen` has one: a
        // `fullScreenCover` presents over what is already there and a tvOS
        // `List` paints no background of its own, so this arrived as a
        // keyboard and a column of spot names floating on the favourites
        // board behind it.
        ZStack {
            Color.black.ignoresSafeArea()
            NavigationStack(path: $path) {
                List {
                if !matches.isEmpty {
                    Section("Matches") {
                        ForEach(matches) { SpotRow(spot: $0) }
                    }
                } else if searching {
                    Text("Nothing by that name")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                } else {
                    if !nearby.isEmpty {
                        Section(nearbyTitle) {
                            ForEach(nearby) { SpotRow(spot: $0) }
                        }
                    }
                    if !starred.isEmpty {
                        Section("Saved") {
                            ForEach(starred) { SpotRow(spot: $0) }
                        }
                    }
                    Section("Browse by country") {
                        // Somebody's own country is the one they want, and it
                        // is rarely first alphabetically — so the ones
                        // carrying the most launches lead, which in practice
                        // puts it near the top.
                        ForEach(guide.countries.sorted { $0.spotCount > $1.spotCount }) { region in
                            NavigationLink(value: region) {
                                HStack {
                                    Text(region.name).font(.system(size: 32))
                                    Spacer()
                                    Text("\(region.spotCount)")
                                        .font(.system(size: 26))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
                .navigationTitle("Your spots")
                .searchable(text: $query, prompt: "Spot, town or region")
                .navigationDestination(for: GuideRegion.self) { region in
                    SpotPicker(title: region.name, spots: guide.spots(inCountry: region))
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        // One press, one level — the same rule as the conditions screen, and
        // needed for the same reason: a stack inside a modal does not divide
        // Menu sensibly with the modal, so nothing here relies on it trying.
        .onExitCommand {
            if path.isEmpty { dismiss() } else { path.removeLast() }
        }
    }

    private var searching: Bool {
        query.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// Matched on everything a rider might type: the launch's own name, the
    /// region it sits in, the country. Capped because a television list is
    /// crossed with a thumb on a glass rectangle.
    private var matches: [GuideSpot] {
        let fragment = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard fragment.count >= 2 else { return [] }
        return guide.spots
            .filter { spot in
                spot.name.lowercased().contains(fragment)
                || (spot.adminRegion?.lowercased().contains(fragment) ?? false)
                || (spot.country?.lowercased().contains(fragment) ?? false)
            }
            // A name that starts with what was typed is what was meant.
            .sorted { a, b in
                let aLeads = a.name.lowercased().hasPrefix(fragment)
                let bLeads = b.name.lowercased().hasPrefix(fragment)
                if aLeads != bLeads { return aLeads }
                return a.name < b.name
            }
            .prefix(25)
            .map { $0 }
    }

    /// The launches around wherever the map is pointed — the answer for the
    /// household setting this up for the coast they can see out of the window.
    private var nearby: [GuideSpot] {
        guard let here = location.here else { return [] }
        return guide.spots
            .map { ($0, Geo.distance(here, .init(latitude: $0.latitude, longitude: $0.longitude))) }
            .filter { $0.1 < 150_000 }
            .sorted { $0.1 < $1.1 }
            .prefix(12)
            .map(\.0)
    }

    /// Only a place somebody *named* goes in the heading. The generic name a
    /// bare network fix carries turns this into "Near Nearby" — the same
    /// mistake the camera list's empty state made, and the reason both now
    /// ask `isChosen` rather than whether the string is empty.
    private var nearbyTitle: String {
        location.isChosen && !location.name.isEmpty ? "Near \(location.name)" : "Nearby"
    }

    private var starred: [GuideSpot] { guide.favorites }
}

/// One launch, and whether it is on the board.
///
/// Starring does not leave the list. Setting the board up means picking four
/// or five in a row, and a screen that popped back after each one would make
/// somebody drill in five times.
private struct SpotRow: View {

    let spot: GuideSpot

    @Environment(SpotGuideStore.self) private var guide

    var body: some View {
        let starred = guide.favoriteIds.contains(spot.spotId)
        Button { guide.toggleFavorite(spot.spotId) } label: {
            HStack(spacing: 24) {
                Image(systemName: starred ? "star.fill" : "star")
                    .font(.system(size: 28))
                    .foregroundStyle(starred ? Color.accentColor : .secondary)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.name)
                        .font(.system(size: 32))
                        .lineLimit(1)
                    // The region under the name, not beside it: two launches
                    // called Long Beach are told apart by where they are, and
                    // a trailing label gets pushed off by the longer name.
                    Text(spot.where_)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }
}

/// The launches in one country.
private struct SpotPicker: View {

    let title: String
    let spots: [GuideSpot]

    var body: some View {
        List {
            ForEach(spots.sorted { $0.name < $1.name }) { SpotRow(spot: $0) }
        }
        .navigationTitle(title)
    }
}
