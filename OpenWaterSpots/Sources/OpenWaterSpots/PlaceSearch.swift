import Foundation
import MapKit
import Observation
import OpenWaterCore

/// A place the guide has never heard of.
///
/// Lives in the package rather than in the phone because the television
/// needs the same answer: an Apple TV that cannot get a fix has nothing but
/// a name somebody types, and resolving that name is this file's whole job.
///
/// Search knows two kinds of answer: a curated spot, which is a page, and a
/// place, which is only somewhere — a town, a beach, a harbour from Apple's
/// geocoder. A place is not a navigation destination and never enters the
/// path; choosing one is a camera move, and the centre pin does the rest.
public struct PlaceResult: Hashable, Sendable {
    public let name: String
    public let subtitle: String
    public let latitude: Double
    public let longitude: Double

    public init(name: String, subtitle: String, latitude: Double, longitude: Double) {
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }

    public var coordinate: Geo.Coordinate {
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
public final class PlaceSearchModel: NSObject {

    /// One row of the Places section. Hashable identity is the visible
    /// text, which is also exactly what makes two rows redundant.
    public struct Completion: Identifiable, Hashable {
        public let title: String
        public let subtitle: String
        fileprivate let raw: MKLocalSearchCompletion

        public var id: String { title + "|" + subtitle }
        public static func == (a: Completion, b: Completion) -> Bool { a.id == b.id }
        public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    public private(set) var completions: [Completion] = []
    private let completer = MKLocalSearchCompleter()
    private var debounce: Task<Void, Never>?

    public override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    public var query: String = "" {
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
    public func bias(to region: MKCoordinateRegion?) {
        if let region { completer.region = region }
    }

    /// A completion is only a string until Apple is asked where it is.
    /// Failure returns nil and the overlay stays put — no alert for a
    /// geocoder hiccup.
    public func resolve(_ completion: Completion) async -> PlaceResult? {
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

    public func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results.map {
            Completion(title: $0.title, subtitle: $0.subtitle, raw: $0)
        }
    }

    public func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // Offline, or the geocoder is sulking — the Places section simply
        // is not there, and spots and regions keep answering.
        completions = []
    }
}
