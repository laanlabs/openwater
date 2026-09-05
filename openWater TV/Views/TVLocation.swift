import CoreLocation
import MapKit
import OpenWaterCore
import OpenWaterSpots
import SwiftUI

/// Where the television thinks it is.
///
/// An Apple TV is the one device in this app with no idea where it is and no
/// way to be carried somewhere else. tvOS gives exactly two calls —
/// `requestWhenInUseAuthorization` and a one-shot `requestLocation`, no
/// `startUpdatingLocation` at all — and what comes back is a coarse fix
/// derived from the network rather than a receiver. That is fine for the only
/// question being asked, which is which stretch of coast to open the map on.
///
/// It can also come back with nothing: Location Services off at the system
/// level, an unshared network, a box in a house that has never been asked.
/// So the fix is a suggestion and a typed place is the answer — whichever a
/// rider last chose wins, and it is remembered, because a television is set up
/// once and then watched for a year.
@MainActor
@Observable
final class TVLocation: NSObject {

    /// What the map should open on, and where the cameras count their
    /// distance from. A chosen place beats a fix on purpose: somebody who
    /// went to the trouble of typing "Tarifa" is not asking to be shown the
    /// living room again on the next launch.
    var here: Geo.Coordinate? { chosen?.coordinate ?? fix }

    /// What to call it on screen. The fix has no name worth printing — a
    /// reverse geocode of a coarse network location says a suburb three
    /// towns over — so it is simply "Nearby".
    var name: String { chosen?.name ?? (fix != nil ? "Nearby" : "") }

    /// Whether the rider picked this rather than the box guessing it.
    var isChosen: Bool { chosen != nil }

    /// What the wind map is actually showing, centre and span, written on
    /// every settle.
    ///
    /// Here rather than inside the map because the Radar tab opens on it: a
    /// rider who has just panned to Montauk and pressed across means Montauk,
    /// at that zoom, and asking them to drive a second map to the same place
    /// is the app forgetting something it was told ten seconds ago. Nil until
    /// the map has settled once, which is the only reason radar has a
    /// fallback box at all.
    var mapRegion: MKCoordinateRegion?

    /// A point the wind map has been asked to show, without keeping it.
    ///
    /// This is what a starred spot's "see it on the map" row sets. It is
    /// deliberately not `choose`: the pin is the place the *app* is about —
    /// the cameras tab counts from it, the next launch opens on it — and a
    /// rider who wants to look at the wash over one of their spots for a
    /// minute has not said any of that. So the map goes there, and the pin
    /// stays where it was.
    ///
    /// Stamped with an id so asking for the same spot twice is two asks: the
    /// second press has to move a map that may have been panned away since.
    struct Glance: Equatable {
        let coordinate: Geo.Coordinate
        let name: String
        let id = UUID()
    }

    private(set) var glance: Glance?

    /// A glance asked for but not yet handed to the map. See `showGlance`.
    private var pendingGlance: Glance?

    /// Ask for this point on the wind map. Queued, not shown: the ask comes
    /// from inside a full-screen report over the favourites tab, and the tab
    /// switch it wants cannot happen while that cover is still dismissing —
    /// the selection flipped to the map and was put straight back, so the
    /// rider saw the board again with the map untouched. The board delivers
    /// it from the cover's own dismissal callback instead. See `Glance`.
    func lookAt(_ coordinate: Geo.Coordinate, named name: String) {
        pendingGlance = Glance(coordinate: coordinate, name: name)
    }

    /// The cover is down; the map can have the glance now. Nothing pending
    /// is nothing to do, which is what every ordinary dismissal is.
    func showGlance() {
        guard let pendingGlance else { return }
        glance = pendingGlance
        self.pendingGlance = nil
    }

    /// The look is over. Pressed on the map's own way back; also implied by
    /// anything that names a new place — see `choose` and `useTheFix`.
    func endGlance() {
        glance = nil
    }

    /// How the search for a fix has gone. Not the same question as `here`:
    /// a refused fix with a chosen place is a working screen, and this is
    /// only what the "use my location" button has to say for itself.
    enum FixState: Equatable {
        case idle
        case locating
        case found
        /// Asked and told no — Location Services off, or the box declined.
        case refused
        /// Allowed, asked, and nothing came back.
        case failed
    }

    private(set) var fixState: FixState = .idle

    /// Nothing to draw and nothing left to try: the screen has to ask for a
    /// place. The one state the map cannot paint its way out of.
    ///
    /// `idle` is *not* in here. The very first body evaluation happens before
    /// the screen's `onAppear` has asked for anything, and treating that
    /// instant as failure flashes "this Apple TV doesn't know where it is" at
    /// a rider one frame before the system's own permission prompt goes up.
    var needsAPlace: Bool {
        here == nil && (fixState == .refused || fixState == .failed)
    }

    // MARK: Storage

    /// A place a rider typed, kept whole so the next launch opens on it. The
    /// name goes in beside the numbers because re-deriving it would mean a
    /// geocode at launch for a string the rider already read once.
    private struct Chosen: Codable {
        let name: String
        let latitude: Double
        let longitude: Double
        var coordinate: Geo.Coordinate {
            Geo.Coordinate(latitude: latitude, longitude: longitude)
        }
    }

    private static let storageKey = "tv.place"

    private var chosen: Chosen? {
        didSet {
            guard let chosen else {
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
                return
            }
            if let data = try? JSONEncoder().encode(chosen) {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        }
    }

    private var fix: Geo.Coordinate?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        if let data = UserDefaults.standard.data(forKey: Self.storageKey) {
            chosen = try? JSONDecoder().decode(Chosen.self, from: data)
        }
    }

    // MARK: Asking

    /// Ask the box where it is. Safe to call on every appearance: a granted
    /// authorization goes straight to the one-shot, a refused one returns
    /// without a round trip, and an undecided one puts the system prompt up
    /// exactly once.
    func locate() {
        switch manager.authorizationStatus {
        case .notDetermined:
            fixState = .locating
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            fixState = .locating
            manager.requestLocation()
        default:
            fixState = .refused
        }
    }

    /// A place from the search, or a spot the rider picked off the guide.
    ///
    /// Naming a place ends any glance: the pin dropped where the rider was
    /// looking makes the look the place, and a typed place is somewhere else
    /// on purpose. Either way "back to the pin" no longer means anything.
    func choose(name: String, at coordinate: Geo.Coordinate) {
        glance = nil
        chosen = Chosen(name: name,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude)
    }

    func choose(_ place: PlaceResult) {
        choose(name: place.name, at: place.coordinate)
    }

    func choose(_ spot: GuideSpot) {
        choose(name: spot.name,
               at: Geo.Coordinate(latitude: spot.latitude, longitude: spot.longitude))
    }

    /// Give the box its own answer back. Asks for a fresh fix if there is
    /// none, so "use my location" is one press whatever state it is in.
    func useTheFix() {
        glance = nil
        chosen = nil
        if fix == nil { locate() }
    }
}

/// The receiver calls back on the main queue; `@preconcurrency` lets the
/// main-actor model say so without a nonisolated trampoline — the same shape
/// `PlaceSearchModel` uses for `MKLocalSearchCompleter`.
extension TVLocation: @preconcurrency CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            fixState = .locating
            manager.requestLocation()
        case .notDetermined:
            break
        default:
            fixState = .refused
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        fix = Geo.Coordinate(latitude: last.coordinate.latitude,
                             longitude: last.coordinate.longitude)
        fixState = .found
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to retry. tvOS has no receiver to warm up, so a failure
        // here means the box genuinely cannot say — which is the case the
        // search screen exists for.
        fixState = .failed
    }
}
