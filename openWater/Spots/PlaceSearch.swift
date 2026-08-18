import Foundation
import MapKit
import OpenWaterCore

/// A place the guide has never heard of.
///
/// Search knows two kinds of answer: a curated spot, which is a page, and a
/// place, which is only somewhere — a town, a beach, a harbour from Apple's
/// geocoder. A place is not a navigation destination and never enters the
/// path; choosing one is a camera move, and the centre pin does the rest.
struct PlaceResult: Hashable {
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var coordinate: Geo.Coordinate {
        Geo.Coordinate(latitude: latitude, longitude: longitude)
    }
}

/// Live place completions for the search overlay.
///
/// `MKLocalSearchCompleter` does its own throttling badly and cancellation
/// not at all, so the model debounces a quarter second of typing before
/// handing the fragment over, and an emptied query drops the results rather
/// than waiting for the completer to notice.
@MainActor
@Observable
final class PlaceSearchModel: NSObject {

    /// One row of the Places section. Hashable identity is the visible
    /// text, which is also exactly what makes two rows redundant.
    struct Completion: Identifiable, Hashable {
        let title: String
        let subtitle: String
        fileprivate let raw: MKLocalSearchCompletion

        var id: String { title + "|" + subtitle }
        static func == (a: Completion, b: Completion) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private(set) var completions: [Completion] = []
    private let completer = MKLocalSearchCompleter()
    private var debounce: Task<Void, Never>?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            debounce?.cancel()
            let fragment = query.trimmingCharacters(in: .whitespaces)
            guard fragment.count >= 2 else {
                completions = []
                completer.cancel()
                return
            }
            debounce = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                completer.queryFragment = fragment
            }
        }
    }

    /// Bias the completer to what the map is showing. Without a region it
    /// leans hard toward the US, which is the wrong answer for a rider
    /// browsing Tarifa.
    func bias(to region: MKCoordinateRegion?) {
        if let region { completer.region = region }
    }

    /// A completion is only a string until Apple is asked where it is.
    /// Failure returns nil and the overlay stays put — no alert for a
    /// geocoder hiccup.
    func resolve(_ completion: Completion) async -> PlaceResult? {
        let request = MKLocalSearch.Request(completion: completion.raw)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first
        else { return nil }
        let coordinate = item.placemark.coordinate
        return PlaceResult(
            name: completion.title.isEmpty ? (item.name ?? "Somewhere") : completion.title,
            subtitle: completion.subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}

/// The completer calls back on the main queue; `@preconcurrency` lets the
/// main-actor model say so without a nonisolated trampoline.
extension PlaceSearchModel: @preconcurrency MKLocalSearchCompleterDelegate {

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results.map {
            Completion(title: $0.title, subtitle: $0.subtitle, raw: $0)
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Offline, or the geocoder is sulking — the Places section simply
        // is not there, and spots and regions keep answering.
        completions = []
    }
}
