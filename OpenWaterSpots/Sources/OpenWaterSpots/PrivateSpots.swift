import CoreLocation
import Foundation
import OpenWaterCore

/// A spot that never leaves the phone.
///
/// The guide is public and human-reviewed, which is right for a launch
/// everybody shares and wrong for the sandbar only you know about, or the
/// stretch in front of a friend's house. A private spot is the other path:
/// no submission, no review, no server — a name and a coordinate in local
/// storage, listed with the favorites, and the conditions sheet gives it
/// the same stations, forecasts and cams every guide spot gets.
public struct PrivateSpot: Codable, Identifiable, Hashable, Sendable {

    /// Memberwise, spelled out because the synthesised one is internal
    /// and this type is read from the apps.
    public init(id: UUID, name: String, latitude: Double, longitude: Double, createdAt: Date, shoreFacingDeg: Double? = nil) { self.id = id; self.name = name; self.latitude = latitude; self.longitude = longitude; self.createdAt = createdAt; self.shoreFacingDeg = shoreFacingDeg }
    public let id: UUID
    public var name: String
    public let latitude: Double
    public let longitude: Double
    public let createdAt: Date
    /// Degrees true from the beach out toward open water. Optional twice
    /// over: old saved spots decode without it, and nobody is made to
    /// answer a question they are unsure of — the surf screens fall back
    /// to their proxy and say so.
    public var shoreFacingDeg: Double?

    public var coordinate: Geo.Coordinate {
        Geo.Coordinate(latitude: latitude, longitude: longitude)
    }

    public var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
