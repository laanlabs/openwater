import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// The screen the app opens on: your spots, and what the wind is doing at each.
///
/// One row per spot and nothing else on it. The phone's favourites row carries
/// a glyph, a name, an arrow and a number because that is what fits under a
/// thumb; here the same four things are simply enormous, because the reader is
/// three metres away and holding a cup of coffee rather than a phone.
///
/// The banner above them is the actual answer. "Two spots are firing" is what
/// somebody came to the television to find out, and if it is nobody they can
/// stop reading at the first line and go back to bed.
struct FavoritesBoard: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(TVLocation.self) private var location

    @State private var isEditing = false

    /// Live wind for every starred spot is a single request — Open-Meteo takes
    /// comma-separated coordinate lists — so this can run on a short loop
    /// without being rude. `refreshWind` drops anything inside its ten-minute
    /// TTL, so the timer costs nothing most times it fires.
    private static let refreshInterval: Duration = .seconds(300)

    private var favorites: [GuideSpot] { guide.favorites }

    /// Live wind for the rider's own pins, which the guide's bulk refresh
    /// cannot fetch because it works in `GuideSpot`s and a pin is not one.
    @State private var pinWind: [UUID: WindReading] = [:]

    /// Everything on the board: the starred guide spots and the pins a rider
    /// dropped themselves.
    ///
    /// Private pins used to be saved and then never seen again — `favorites`
    /// resolves ids against the guide, so a pin, which is not in the guide,
    /// silently vanished from the one screen it was made for. They are their
    /// own kind of row now rather than being forced to look like a listed
    /// spot.
    private enum Entry: Identifiable {
        case spot(GuideSpot)
        case pin(PrivateSpot)

        var id: String {
            switch self {
            case .spot(let spot): "spot:" + spot.spotId
            case .pin(let pin): "pin:" + pin.id.uuidString
            }
        }

        var name: String {
            switch self {
            case .spot(let spot): spot.name
            case .pin(let pin): pin.name
            }
        }

        var isPin: Bool {
            if case .pin = self { return true }
            return false
        }
    }

    private var entries: [Entry] {
        favorites.map(Entry.spot) + guide.privateSpots.map(Entry.pin)
    }

    private func remove(_ entry: Entry) {
        switch entry {
        case .spot(let spot): guide.removeFavorite(spot.spotId)
        case .pin(let pin): guide.removePrivateSpot(pin.id)
        }
    }

    private func reading(for entry: Entry) -> WindReading? {
        switch entry {
        case .spot(let spot): guide.wind[spot.spotId]
        case .pin(let pin): pinWind[pin.id]
        }
    }

    private var firing: [GuideSpot] {
        favorites.filter { guide.wind[$0.spotId]?.isFiring == true }
    }

    /// The row a rider pressed, presented as a cover.
    @State private var route: Entry?

    /// Whether pressing a row removes it instead of opening it.
    ///
    /// A mode rather than a control on every row. There is no swipe on a
    /// television and no room beside a row for a delete button that would sit
    /// there unread for the ninety-nine per cent of presses that mean "open
    /// this" — so the board has one state where a press opens and another
    /// where a press removes, and says loudly which one it is in.
    @State private var isDeleting = false

    /// The row awaiting a yes. Deleting is the one thing on this screen that
    /// cannot be undone, and the remote is a surface people press by accident.
    @State private var pendingDelete: Entry?

    var body: some View {
        Group {
            if guide.spots.isEmpty && guide.isLoading {
                LoadingBoard()
            } else if entries.isEmpty {
                EmptyBoard { isEditing = true }
            } else {
                board
            }
        }
        // The report, over the board, rather than pushed onto it.
        //
        // This screen used to use `NavigationLink(value:)` and a matching
        // `navigationDestination`, and pressing a spot did nothing at all. The
        // path grew and the destination closure ran — both were verified on
        // the simulator — but a `NavigationStack` living inside a tvOS
        // `TabView` tab never presented what it had built. Every other detail
        // in this app is a cover for the same reason: the cameras list, the
        // map's search, the map's own conditions report.
        // `onDismiss` is where a report's "see it on the map" actually goes
        // to the map: switching tabs underneath a cover that is still on its
        // way out does not take. See `TVLocation.lookAt`.
        .fullScreenCover(item: $route, onDismiss: location.showGlance) { entry in
            // Its own stack, so the report's sub-screens — the wind outlook,
            // the tide, the buoys — still push the way they do from the map.
            NavigationStack {
                switch entry {
                case .spot(let spot):
                    SpotScreen(spot: spot)
                case .pin(let pin):
                    ConditionsScreen(here: pin.coordinate, placeName: pin.name,
                                     openedFromBoard: true)
                }
            }
        }
        // Full screen, not a sheet. tvOS sheets are a narrow centre column,
        // and `searchable` puts a whole keyboard inside this one: in a sheet
        // the prompt truncates mid-word, the letters crowd, and the results
        // get about a third of a 4K display.
        .fullScreenCover(isPresented: $isEditing) { EditFavoritesScreen() }
        .alert("Remove \(pendingDelete?.name ?? "")?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } })) {
            Button("Remove", role: .destructive) {
                if let entry = pendingDelete { remove(entry) }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("It comes off this board. Nothing else about it changes.")
        }
        // Coming back to a board still armed for deletion is how somebody
        // loses a spot they meant to open.
        .onChange(of: entries.isEmpty) { _, empty in if empty { isDeleting = false } }
        .task(id: guide.privateSpots.map(\.id.uuidString).joined()) {
            // One request each, and only for the pins — there are a handful
            // at most, and the guide's bulk call cannot speak for them.
            for pin in guide.privateSpots {
                if let reading = await guide.currentWind(at: pin.coordinate) {
                    pinWind[pin.id] = reading
                }
            }
        }
        .task(id: favorites.map(\.spotId).joined()) {
            // A loop rather than a timer: it dies with the view, and the first
            // pass happens the moment the list exists rather than one interval
            // later, which is the pass that matters on a screen somebody just
            // turned on.
            while !Task.isCancelled {
                await guide.refreshWind(for: favorites)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if isDeleting {
                    DeleteBanner()
                        .padding(.bottom, 8)
                } else {
                    FiringBanner(firing: firing, total: entries.count)
                        .padding(.bottom, 8)
                }

                ForEach(entries) { entry in
                    Button {
                        if isDeleting { pendingDelete = entry } else { route = entry }
                    } label: {
                        FavoriteRow(name: entry.name,
                                    isPin: entry.isPin,
                                    isDeleting: isDeleting,
                                    reading: reading(for: entry))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 28) {
                    // "Add a spot", not "Edit spots". The screen behind it has
                    // only ever been three ways to find somewhere new — type
                    // it, take one nearby, browse by country — and calling
                    // that editing sent riders into it looking for the delete
                    // that was not there.
                    Button("Add a spot") { isEditing = true }
                    Button(isDeleting ? "Done" : "Delete spots") {
                        isDeleting.toggle()
                    }
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
    }
}

// MARK: - The answer, in one line

/// "Three of your spots are firing — Rufus, Doug's, Stevenson."
///
/// Named rather than counted wherever they fit. A number alone sends somebody
/// down the list to find out which; the names end the question on the first
/// line, which is the entire job of this screen.
private struct FiringBanner: View {

    let firing: [GuideSpot]
    let total: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Image(systemName: firing.isEmpty ? "wind" : "flame.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(firing.isEmpty ? .secondary : Color.accentColor)
            Text(headline)
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .foregroundStyle(firing.isEmpty ? Color.secondary : Color.white)
            Spacer()
        }
    }

    private var headline: String {
        guard !firing.isEmpty else {
            return total == 0 ? "Nothing saved yet" : "Nothing firing right now"
        }
        let names = firing.prefix(3).map(\.name).joined(separator: ", ")
        let count = firing.count == 1 ? "1 spot is firing" : "\(firing.count) spots are firing"
        return firing.count > 3 ? "\(count) — \(names)…" : "\(count) — \(names)"
    }
}

// MARK: - One spot

/// Name on the left, wind on the right, nothing in between.
///
/// The number is `monospacedDigit` for the reason the watch's speed page is:
/// these refresh under the reader, and proportional digits make the whole row
/// twitch sideways when 9 becomes 10.
/// What the board is doing, while it is doing something unusual.
///
/// It replaces the firing banner rather than sitting under it. The headline
/// is the one line a rider reads from the sofa, and while the board is armed
/// the thing they need to know is not which spots are windy.
private struct DeleteBanner: View {

    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose a spot to remove")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
                Text("It will ask before it removes anything. Press Done when you have finished.")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct FavoriteRow: View {

    let name: String
    /// A pin of the rider's own rather than a listed launch — marked, because
    /// the two came from different places and one of them is not in the guide.
    let isPin: Bool
    /// The board is in delete mode, so this row is a thing that goes away.
    var isDeleting = false
    let reading: WindReading?

    @Environment(\.isFocused) private var isFocused

    /// Focused-while-deleting is its own colour. tvOS inverts a focused row
    /// to something pale and friendly, which is the wrong promise to make
    /// about the press that removes it.
    private var rowFill: Color {
        if isDeleting && isFocused { return Color.red.opacity(0.35) }
        return isFocused ? Color.primary.opacity(0.14) : Color.primary.opacity(0.05)
    }

    /// The row's own text colour: dark on the focused row's light halo, white
    /// on the dark board. Deleting keeps white, because that row is red.
    private var ink: Color {
        isFocused && !isDeleting ? .black : .white
    }

    /// The quieter half of the row — the cardinal, the units, the gust — at a
    /// contrast that survives both grounds rather than a fixed grey that only
    /// works on one.
    private var quietInk: Color {
        isFocused && !isDeleting ? Color.black.opacity(0.6) : Color.white.opacity(0.65)
    }

    var body: some View {
        HStack(spacing: 32) {
            if isDeleting {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
            }
            if isPin {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(quietInk)
            }
            Text(name)
                .font(.system(size: 40, weight: .medium))
                // Literal colours, not `.primary`: inside a focusable button
                // tvOS resolves `.primary` to the app's accent, so a board
                // built from links comes out entirely brand blue — the loudest
                // thing on screen sitting on the part nobody is reading.
                //
                // Which literal, though, has to follow the focus. tvOS paints
                // the focused row with its own near-white halo, and white text
                // on it was white on white: the one row a rider is looking at
                // was the one row they could not read.
                .foregroundStyle(ink)
                .lineLimit(1)
            Spacer(minLength: 40)
            if let reading {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 26))
                    .rotationEffect(.degrees(reading.directionDeg + 180))
                    .foregroundStyle(quietInk)
                Text(reading.cardinal)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(quietInk)
                    .frame(width: 90, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(Int(reading.speedKn.rounded()))")
                        .font(.system(size: 62, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("kn").font(.system(size: 24, weight: .semibold))
                        if let gust = reading.gustKn {
                            Text("g\(Int(gust.rounded()))")
                                .font(.system(size: 22))
                                .foregroundStyle(quietInk)
                                .monospacedDigit()
                        }
                    }
                }
                // Firing keeps the tint on both grounds; the accent is dark
                // enough to read on the halo and bright enough on the board.
                .foregroundStyle(reading.isFiring ? Color.accentColor : ink)
                .frame(width: 190, alignment: .leading)
            } else {
                // A blank, not a spinner. The row is the right height already
                // and a spinner on every row reads as a broken screen.
                Text("—")
                    .font(.system(size: 62, weight: .heavy, design: .rounded))
                    .foregroundStyle(quietInk.opacity(0.5))
                    .frame(width: 190, alignment: .leading)
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 20))
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Before there is anything to show

private struct LoadingBoard: View {
    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
            Text("Loading the guide…")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        }
    }
}

private struct EmptyBoard: View {

    let edit: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "star")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text("No spots saved yet")
                .font(.system(size: 46, weight: .bold))
            Text("Pick the launches you actually go to. They live here with live\nwind, so \"is it on?\" is answered the moment you turn the TV on.")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add spots", action: edit)
                .padding(.top, 12)
        }
        .padding(60)
    }
}
