import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Typing a place in, for the box that cannot work out where it is.
///
/// Two kinds of answer, kept apart the way the phone's search overlay keeps
/// them: a spot the guide already knows, which comes with a name a rider
/// recognises and a launch under it, and a place from Apple's geocoder, which
/// is only somewhere. The guide goes first because a rider searching "Napeague"
/// on a wind app means the launch, not the hamlet.
///
/// `searchable` is doing real work here. On tvOS it puts the system's own
/// keyboard on the left and the results on the right, focus moves between them
/// with the D-pad, and dictation is free — which is the difference between
/// entering a place name on a television and giving up.
struct PlaceSearchScreen: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVLocation.self) private var location
    @Environment(\.dismiss) private var dismiss

    /// Bias for the geocoder: what the map is showing, so a fragment resolves
    /// near the coast being browsed rather than in the middle of Kansas.
    let near: MKCoordinateRegion?

    @State private var query = ""
    @State private var places = PlaceSearchModel()
    @State private var isResolving = false

    var body: some View {
        // An opaque ground under the whole thing.
        //
        // A `fullScreenCover` presents over what is already there, and a
        // `List` on tvOS draws no background of its own — so this arrived as a
        // keyboard and a column of place names floating directly on the wind
        // map, both illegible. Reported exactly that way: "the whole screen is
        // jumbled". A search screen is not chrome over a map; it is a screen.
        ZStack {
            Color.black.ignoresSafeArea()
            NavigationStack {
                List {
                if location.fixState != .refused {
                    useMyLocation
                }
                if !matchingSpots.isEmpty {
                    Section("Spots") {
                        ForEach(matchingSpots) { spot in
                            Button { pick(spot) } label: { SpotRow(spot: spot) }
                        }
                    }
                }
                if !places.completions.isEmpty {
                    Section("Places") {
                        ForEach(places.completions) { completion in
                            Button { pick(completion) } label: { PlaceRow(completion: completion) }
                        }
                    }
                }
                if query.count >= 2 && matchingSpots.isEmpty && places.completions.isEmpty {
                    Text("Nothing by that name")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
            }
                .navigationTitle("Where are you?")
                .searchable(text: $query, prompt: "Town, beach or launch")
                .overlay {
                    if isResolving { ProgressView().controlSize(.large) }
                }
            }
        }
        // Deliberately no blanket `foregroundStyle(.white)` here.
        //
        // A tvOS `List` row inverts when it takes focus — white pill, black
        // text — and it works that out from `.primary`. Forcing white
        // overrode that inversion and left the focused row white-on-white:
        // an invisible row exactly where the rider is looking, which is how
        // it was reported. The dark palette is guaranteed once, at the root,
        // by `preferredColorScheme(.dark)`; these rows only have to leave
        // their colour alone and let focus do its job.
        // Menu, answered explicitly. A `NavigationStack` inside a
        // `fullScreenCover` takes the button and — with nothing to pop —
        // does nothing with it, which strands a rider on this screen. Flat
        // stack here, so there is no depth to check.
        .onExitCommand { dismiss() }
        .onChange(of: query) { _, new in places.query = new }
        .onAppear { places.bias(to: near) }
    }

    /// Offered whenever the box has not already been told no. Its own row
    /// rather than a corner button: on a screen whose whole job is answering
    /// "where are you", "you already know" is one of the answers.
    private var useMyLocation: some View {
        Button {
            location.useTheFix()
            dismiss()
        } label: {
            Label {
                Text(location.fixState == .found ? "Use my location" : "Try my location")
                    .font(.system(size: 32, weight: .medium))
            } icon: {
                Image(systemName: "location.fill")
            }
        }
    }

    /// The guide, matched on everything a rider might type: the spot's own
    /// name, the region it sits in, the country. Capped because a television
    /// list is scrolled with a thumb on a glass rectangle.
    private var matchingSpots: [GuideSpot] {
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
            .prefix(20)
            .map { $0 }
    }

    private func pick(_ spot: GuideSpot) {
        location.choose(spot)
        dismiss()
    }

    /// A completion is a string until Apple is asked where it is, so this is
    /// the one row press that has to wait. Failure leaves the screen up: a
    /// geocoder hiccup is not worth an alert, and the next row down probably
    /// works.
    private func pick(_ completion: PlaceSearchModel.Completion) {
        isResolving = true
        Task {
            defer { isResolving = false }
            guard let place = await places.resolve(completion) else { return }
            location.choose(place)
            dismiss()
        }
    }
}

// MARK: - Rows

private struct SpotRow: View {

    let spot: GuideSpot

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(spot.name)
                    .font(.system(size: 32, weight: .medium))
                    .lineLimit(1)
                Text(spot.where_)
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}

private struct PlaceRow: View {

    let completion: PlaceSearchModel.Completion

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(completion.title)
                    .font(.system(size: 32, weight: .medium))
                    .lineLimit(1)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }
}
