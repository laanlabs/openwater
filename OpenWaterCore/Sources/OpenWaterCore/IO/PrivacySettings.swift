import Foundation

/// Controls what leaves the device.
///
/// The most sensitive data in a GPS track is not the speed — it is the first and
/// last hundred metres. A launch point is somebody's driveway, their parked car,
/// or a beach access that the people who use it would rather not see published.
/// A rider who shares a session to show off a 28-knot run has no intention of
/// also publishing where they live, and should not have to think about it.
///
/// So trimming is **on by default for anything shared or exported**, and the
/// stored session is never modified — masking is applied to a copy on the way
/// out. The rider's own data stays complete.
public struct PrivacySettings: Hashable, Sendable, Codable {

    /// Trim this many metres of track from the start and end.
    ///
    /// 200 m is enough to obscure a specific car park or house while leaving the
    /// session's shape and every metric intact.
    public var endpointMaskRadius: Double

    /// Apply the trim. On by default; a rider exporting for their own backup can
    /// turn it off.
    public var maskEndpoints: Bool

    /// Strip the notes field.
    public var includeNotes: Bool

    /// Strip the spot name, which can be as identifying as the coordinates.
    public var includeSpotName: Bool

    /// Include heart rate. Health data has a different sensitivity from speed
    /// data and gets its own switch.
    public var includeHeartRate: Bool

    /// Include the recording device model and app version.
    public var includeDeviceInfo: Bool

    /// Round timestamps to the nearest minute, so a shared file does not reveal
    /// exactly when somebody was away from home.
    public var coarsenTimestamps: Bool

    public init(
        endpointMaskRadius: Double = 200,
        maskEndpoints: Bool = true,
        includeNotes: Bool = true,
        includeSpotName: Bool = true,
        includeHeartRate: Bool = true,
        includeDeviceInfo: Bool = true,
        coarsenTimestamps: Bool = false
    ) {
        self.endpointMaskRadius = endpointMaskRadius
        self.maskEndpoints = maskEndpoints
        self.includeNotes = includeNotes
        self.includeSpotName = includeSpotName
        self.includeHeartRate = includeHeartRate
        self.includeDeviceInfo = includeDeviceInfo
        self.coarsenTimestamps = coarsenTimestamps
    }

    /// Nothing removed — for a rider's own complete backup.
    public static let none = PrivacySettings(
        endpointMaskRadius: 0,
        maskEndpoints: false
    )

    /// The safe default for sharing with anyone else.
    public static let sharing = PrivacySettings()

    /// Maximum caution: endpoints trimmed hard, everything optional stripped.
    public static let strict = PrivacySettings(
        endpointMaskRadius: 500,
        maskEndpoints: true,
        includeNotes: false,
        includeSpotName: false,
        includeHeartRate: false,
        includeDeviceInfo: false,
        coarsenTimestamps: true
    )

    // MARK: - Apply

    /// Return a copy of the session with these settings applied.
    ///
    /// The summary is recomputed rather than carried over, because a trimmed
    /// track genuinely has a different distance and duration, and shipping the
    /// untrimmed numbers alongside a trimmed track would both be inconsistent
    /// and leak the length of what was removed.
    public func apply(to session: Session) -> Session {
        var result = session

        if !includeNotes { result.notes = "" }
        if !includeSpotName { result.spotName = nil }
        if !includeDeviceInfo {
            result.deviceModel = nil
            result.appVersion = nil
            result.startBattery = nil
            result.endBattery = nil
        }

        var points = session.track.points

        if !includeHeartRate {
            for i in points.indices { points[i].heartRate = nil }
        }

        if maskEndpoints, endpointMaskRadius > 0 {
            points = Self.trim(points, radius: endpointMaskRadius)
        }

        if coarsenTimestamps {
            for i in points.indices {
                let t = points[i].timestamp.timeIntervalSince1970
                points[i].timestamp = Date(timeIntervalSince1970: (t / 60).rounded() * 60)
            }
        }

        guard points.count != session.track.points.count
                || !includeHeartRate
                || coarsenTimestamps else {
            return result
        }

        let track = TrackBuilder(options: .forSport(session.sport)).build(from: points)
        result.track = track
        result.startDate = track.startDate ?? session.startDate
        result.endDate = track.endDate ?? session.endDate
        result.summary = SessionAnalyzer(
            configuration: .init(
                sport: session.sport,
                categories: SpeedCategory.all,
                wind: session.wind
            )
        ).analyse(track)

        return result
    }

    /// Trim the leading and trailing points that lie within `radius` of the
    /// track's first and last positions.
    ///
    /// **What this protects against, and what it does not.**
    ///
    /// The threat is that a shared track *identifies* a launch point: the first
    /// and last coordinates of an activity are, by construction, where somebody
    /// parked or lives, and they are trivially readable from any GPX. Removing
    /// them removes that signal, and for a point-to-point run — a downwinder,
    /// a coastal crossing — that is complete protection.
    ///
    /// It is **not** a geofence. A rider doing laps in a bay sails back over
    /// their launch point repeatedly, and those interior passes survive the
    /// trim. That is a deliberate limit rather than an oversight: excising every
    /// interior pass would cut a bay session into disconnected fragments and
    /// make its distance and speed figures meaningless. The mitigation is that
    /// once the endpoints are gone, the launch point is no longer distinguishable
    /// from any other part of a track that crosses it many times.
    ///
    /// Riders who need a true exclusion zone need a different feature, and
    /// should not assume this one provides it.
    static func trim(_ points: [TrackPoint], radius: Double) -> [TrackPoint] {
        guard points.count > 2, radius > 0 else { return points }

        let start = points[0].coordinate
        let end = points[points.count - 1].coordinate

        // Advance past everything near the start.
        var lower = 0
        while lower < points.count, Geo.distance(points[lower].coordinate, start) < radius {
            lower += 1
        }

        // Retreat past everything near the end.
        var upper = points.count - 1
        while upper > lower, Geo.distance(points[upper].coordinate, end) < radius {
            upper -= 1
        }

        guard upper > lower else { return [] }
        return Array(points[lower...upper])
    }
}
