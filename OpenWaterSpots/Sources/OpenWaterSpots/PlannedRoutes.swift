import Foundation
import OpenWaterCore

/// A planned point-to-point run: a name, ordered waypoints, and what the
/// rider expects of it.
///
/// Stored the way `PrivateSpot` is — UserDefaults, Codable, decode-with-
/// defaults — and deliberately not SwiftData: that layer holds recorded
/// sessions behind `SessionLibrary`; a route is under a kilobyte of
/// planning content with no relationships. When "route from a past run"
/// arrives it sets `sourceSessionId` and *queries* the library for speeds
/// at read time — history never gets denormalized into the route.
public struct PlannedRoute: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var waypoints: [Geo.Coordinate]
    public let createdAt: Date
    /// Nil rides the app's default sport.
    public var sport: Sport?
    /// The rider's own override; nil takes the sport's cruise default.
    public var expectedSpeedKn: Double?
    /// LATER: set when this route was traced from a recorded session.
    public var sourceSessionId: UUID?

    public init(id: UUID = UUID(), name: String, waypoints: [Geo.Coordinate],
         createdAt: Date = Date(), sport: Sport? = nil,
         expectedSpeedKn: Double? = nil, sourceSessionId: UUID? = nil) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.createdAt = createdAt
        self.sport = sport
        self.expectedSpeedKn = expectedSpeedKn
        self.sourceSessionId = sourceSessionId
    }

    /// Decode with defaults, so routes saved before a field existed still
    /// load — the `shoreFacingDeg` lesson, learned once.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Route"
        waypoints = try container.decodeIfPresent([Geo.Coordinate].self, forKey: .waypoints) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sport = try container.decodeIfPresent(Sport.self, forKey: .sport)
        expectedSpeedKn = try container.decodeIfPresent(Double.self, forKey: .expectedSpeedKn)
        sourceSessionId = try container.decodeIfPresent(UUID.self, forKey: .sourceSessionId)
    }

    public var path: RoutePath { RoutePath(waypoints: waypoints) }

    /// The speed the estimate runs on, in knots: the rider's override, else
    /// the sport's cruise.
    public var speedKn: Double {
        expectedSpeedKn ?? Self.cruiseKn(for: sport)
    }

    /// Typical moving cruise by sport, in knots. Deliberately here and not
    /// in `SportThresholds` — that table tunes detectors against recorded
    /// tracks; this one seeds a guess about a run not yet ridden.
    public static func cruiseKn(for sport: Sport?) -> Double {
        switch sport {
        case .wingfoil: 14
        case .parawing: 12
        case .windfoil: 14
        case .windsurf: 12
        case .kitefoil: 16
        case .kitesurf: 14
        case .downwindSUP: 8
        case .sup: 4
        case .prone: 10
        case .efoil: 15
        case .sail: 6
        case .tow: 15
        default: 8
        }
    }
}

/// The Tools→Spots handoff: another tab asks the Spots map to open a
/// route, or to start drawing one.
///
/// The same two-part shape as the record switch: a static seam holding what
/// to do (the `ScreenshotRoute.requested` pattern — the Spots page may not
/// even be built yet when the ask happens, so a notification alone would
/// fall on deaf ears) and a notification to wake the page when it is
/// already alive. The consumer clears the seam, so a stale ask cannot
/// replay on a later visit.
@MainActor
public enum RouteHandoff: Sendable {
    /// A route the Spots tab should open on arrival.
    public static var pending: PlannedRoute?
    /// Nothing to open — start the editor instead.
    public static var startPlanning = false

    public static func post() {
        NotificationCenter.default.post(name: .openWaterOpenRoute, object: nil)
    }
}

extension Notification.Name {
    public static let openWaterOpenRoute = Notification.Name("openWaterOpenRoute")
}

/// The saved routes, owned by the phone.
@MainActor
@Observable
public final class RouteStore {

    private static let key = "routes.planned"

    public private(set) var routes: [PlannedRoute] = []

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([PlannedRoute].self, from: data) {
            routes = saved
        }
    }

    public func add(_ route: PlannedRoute) {
        routes.append(route)
        save()
    }

    public func remove(_ id: UUID) {
        routes.removeAll { $0.id == id }
        save()
    }

    public func rename(_ id: UUID, to name: String) {
        guard let index = routes.firstIndex(where: { $0.id == id }) else { return }
        routes[index].name = name
        save()
    }

    public func update(_ route: PlannedRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index] = route
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(routes), forKey: Self.key)
    }
}
