import Foundation

/// CSV reading and writing, plus GeoJSON export.
///
/// CSV is the escape hatch: it is what a rider reaches for when they want to
/// look at their own data in a spreadsheet, plot something the app does not
/// plot, or check a number by hand. So the writer emits **every channel**, one
/// row per sample, with a header row naming each — nothing summarised, nothing
/// dropped.
///
/// The reader is deliberately forgiving about column names, because CSVs come
/// from everywhere. It matches on normalised header names and accepts the
/// common aliases each field turns up under.
public enum CSV {

    // MARK: - Writing

    public static func write(session: Session, units: UnitPreferences = .default) -> Data {
        let track = session.track
        let states = session.summary?.states ?? []

        // Two speed columns on purpose.
        //
        // `speed_ms` is the *raw* value the receiver reported. `speed_smoothed_ms`
        // is what the analysis produced after filtering, and is what the app's
        // own numbers are based on. Writing only the smoothed one would make a
        // CSV round trip lossy — reimporting would filter an already-filtered
        // signal and shift every peak — and writing only the raw one would leave
        // a spreadsheet unable to reproduce what the app displayed.
        var out = "timestamp,elapsed_s,latitude,longitude,altitude_m,"
        out += "speed_ms,speed_smoothed_ms,speed_\(units.speed.rawValue),course_deg,"
        out += "distance_m,horizontal_accuracy_m,speed_accuracy_ms,"
        out += "vertical_accel_sd,heart_rate_bpm,cadence,ride_state\n"

        for i in 0..<track.count {
            let p = track.points[i]
            var row: [String] = []
            row.append(GPX.iso8601.format(p.timestamp))
            row.append(GPX.format(track.elapsed[i], 3))
            row.append(GPX.format(p.latitude, 7))
            row.append(GPX.format(p.longitude, 7))
            row.append(p.altitude.map { GPX.format($0, 2) } ?? "")
            row.append(p.speed.map { GPX.format($0, 4) } ?? "")
            row.append(GPX.format(track.speed[i], 4))
            row.append(GPX.format(units.speed.convert(fromMetresPerSecond: track.speed[i]), 3))
            row.append(GPX.format(track.course[i], 2))
            row.append(GPX.format(track.cumulativeDistance[i], 2))
            row.append(p.horizontalAccuracy >= 0 ? GPX.format(p.horizontalAccuracy, 1) : "")
            row.append(p.speedAccuracy.map { GPX.format($0, 2) } ?? "")
            row.append(p.verticalAccelSD.map { GPX.format($0, 3) } ?? "")
            row.append(p.heartRate.map { String(Int($0.rounded())) } ?? "")
            row.append(p.cadence.map { GPX.format($0, 1) } ?? "")
            row.append(states.indices.contains(i) ? states[i].rawValue : "")
            out += row.joined(separator: ",") + "\n"
        }

        return Data(out.utf8)
    }

    // MARK: - Reading

    public static func read(_ data: Data) throws -> ImportedTrack {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ImportError.malformed("The file is not valid UTF-8 text.")
        }

        var lines = text.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { throw ImportError.noTrackPoints }

        let header = lines.removeFirst()
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { normalise(String($0)) }

        /// Find a column by any of its accepted names.
        func column(_ aliases: [String]) -> Int? {
            for alias in aliases {
                if let index = header.firstIndex(of: alias) { return index }
            }
            return nil
        }

        guard let timeIndex = column(["timestamp", "time", "date", "datetime", "utc"]),
              let latIndex = column(["latitude", "lat"]),
              let lonIndex = column(["longitude", "lon", "lng", "long"]) else {
            throw ImportError.malformed(
                "The CSV needs at least timestamp, latitude and longitude columns."
            )
        }

        let altIndex = column(["altitude_m", "altitude", "elevation", "ele", "alt"])
        let speedIndex = column(["speed_ms", "speed", "speed_m_s", "velocity"])
        let speedKnotsIndex = column(["speed_knots", "speed_kn", "knots"])
        let courseIndex = column(["course_deg", "course", "heading", "bearing"])
        let accuracyIndex = column(["horizontal_accuracy_m", "accuracy", "hacc", "hdop"])
        let hrIndex = column(["heart_rate_bpm", "heart_rate", "hr", "heartrate"])
        let cadenceIndex = column(["cadence", "cad"])
        // These two are what make a CSV round trip lossless. Speed accuracy is
        // the weight the smoother uses, so dropping it shifts every peak
        // slightly; vertical acceleration is what flight and fall detection
        // runs on, so without it an exported-then-reimported session silently
        // loses its flights.
        let speedAccuracyIndex = column(["speed_accuracy_ms", "speed_accuracy", "sacc"])
        let accelIndex = column(["vertical_accel_sd", "accel_sd", "vertical_acceleration_sd"])

        var points: [TrackPoint] = []
        points.reserveCapacity(lines.count)

        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            func value(_ index: Int?) -> String? {
                guard let index, index < fields.count else { return nil }
                let v = fields[index].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }

            guard let timeString = value(timeIndex),
                  let timestamp = DateParsing.parse(timeString) ?? unixSeconds(timeString),
                  let latitude = value(latIndex).flatMap(Double.init),
                  let longitude = value(lonIndex).flatMap(Double.init) else { continue }

            // Accept knots where m/s is absent, since a rider hand-editing a
            // file is far more likely to have typed knots.
            let speed = value(speedIndex).flatMap(Double.init)
                ?? value(speedKnotsIndex).flatMap(Double.init).map { $0 / SpeedUnit.knots.perMetrePerSecond }

            points.append(TrackPoint(
                timestamp: timestamp,
                latitude: latitude,
                longitude: longitude,
                altitude: value(altIndex).flatMap(Double.init),
                speed: speed,
                course: value(courseIndex).flatMap(Double.init),
                horizontalAccuracy: value(accuracyIndex).flatMap(Double.init) ?? 0,
                speedAccuracy: value(speedAccuracyIndex).flatMap(Double.init)
                    ?? (speed != nil ? 0 : nil),
                verticalAccelSD: value(accelIndex).flatMap(Double.init),
                heartRate: value(hrIndex).flatMap(Double.init),
                cadence: value(cadenceIndex).flatMap(Double.init)
            ))
        }

        guard !points.isEmpty else { throw ImportError.noTrackPoints }
        return ImportedTrack(points: points, format: .csv)
    }

    private static func normalise(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "\"", with: "")
    }

    /// Some exports use a Unix timestamp rather than an ISO string.
    private static func unixSeconds(_ s: String) -> Date? {
        guard let value = Double(s) else { return nil }
        // Distinguish seconds from milliseconds by magnitude — anything past
        // the year 2100 in seconds is milliseconds.
        return value > 4_000_000_000
            ? Date(timeIntervalSince1970: value / 1000)
            : Date(timeIntervalSince1970: value)
    }
}

// MARK: - GeoJSON

/// GeoJSON export, for dropping a track into a mapping tool.
public enum GeoJSON {

    public static func write(session: Session) throws -> Data {
        let track = session.track
        let summary = session.summary

        // A LineString for the whole track, plus one Feature per state segment
        // so a viewer can style flights differently from swims — which is the
        // whole point of exporting to a map tool rather than a screenshot.
        var features: [[String: Any]] = []

        features.append([
            "type": "Feature",
            "geometry": [
                "type": "LineString",
                "coordinates": track.points.map { [$0.longitude, $0.latitude] },
            ],
            "properties": [
                "name": session.spotName ?? session.sport.displayName,
                "sport": session.sport.rawValue,
                "start": GPX.iso8601.format(session.startDate),
                "distance_m": track.totalDistance,
                "duration_s": track.duration,
                "max_speed_ms": summary?.maxSpeed ?? 0,
            ],
        ])

        for segment in summary?.segments ?? [] {
            guard segment.endIndex > segment.startIndex,
                  segment.endIndex < track.count else { continue }
            features.append([
                "type": "Feature",
                "geometry": [
                    "type": "LineString",
                    "coordinates": track.points[segment.startIndex...segment.endIndex]
                        .map { [$0.longitude, $0.latitude] },
                ],
                "properties": [
                    "state": segment.state.rawValue,
                    "run": segment.runIndex as Any,
                    "average_speed_ms": segment.averageSpeed,
                    "max_speed_ms": segment.maxSpeed,
                    "duration_s": segment.duration,
                ],
            ])
        }

        let root: [String: Any] = ["type": "FeatureCollection", "features": features]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    }
}
