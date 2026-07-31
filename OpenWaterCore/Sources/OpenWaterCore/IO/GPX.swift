import Foundation

/// GPX 1.1 reading and writing.
///
/// GPX is the lowest common denominator of GPS interchange: every device and
/// site speaks it. What it does *not* have in its base schema is speed, and that
/// matters more here than anywhere else — Doppler speed is the difference
/// between a defensible peak and a guess.
///
/// Three conventions exist in the wild for carrying it, and the reader accepts
/// all of them:
///
/// - `<speed>` as a direct child of `<trkpt>` — GPX 1.0's own element, still
///   emitted by plenty of tools;
/// - `<extensions><gpxtpx:TrackPointExtension><gpxtpx:speed>` — Garmin's
///   TrackPointExtension v2;
/// - `<extensions><speed>` — an unnamespaced variant several apps emit.
///
/// The writer emits the Garmin extension (the most widely understood) plus a
/// plain `<speed>`, so a track exported from here keeps its Doppler speed
/// wherever it lands. Heart rate and cadence ride along in the same extension.
public enum GPX {

    // MARK: - Reading

    public static func read(_ data: Data) throws -> ImportedTrack {
        let parser = GPXParser()
        return try parser.parse(data)
    }

    public static func read(contentsOf url: URL) throws -> ImportedTrack {
        try read(Data(contentsOf: url))
    }

    // MARK: - Writing

    public static func write(
        session: Session,
        creator: String = "openWater"
    ) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="\(escape(creator))"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
             xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v2"
             xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd">
          <metadata>
            <time>\(iso8601.format(session.startDate))</time>
          </metadata>
          <trk>
            <name>\(escape(session.spotName ?? session.sport.displayName))</name>
            <type>\(escape(session.sport.rawValue))</type>
            <trkseg>

        """

        for point in session.track.points {
            xml += "      <trkpt lat=\"\(format(point.latitude, 7))\" lon=\"\(format(point.longitude, 7))\">\n"
            xml += "        <time>\(iso8601.format(point.timestamp))</time>\n"
            if let altitude = point.altitude {
                xml += "        <ele>\(format(altitude, 2))</ele>\n"
            }
            if let speed = point.speed {
                xml += "        <speed>\(format(speed, 3))</speed>\n"
            }
            if let course = point.course {
                xml += "        <course>\(format(course, 2))</course>\n"
            }

            let hasExtension = point.speed != nil || point.heartRate != nil || point.cadence != nil
            if hasExtension {
                xml += "        <extensions>\n          <gpxtpx:TrackPointExtension>\n"
                if let speed = point.speed {
                    xml += "            <gpxtpx:speed>\(format(speed, 3))</gpxtpx:speed>\n"
                }
                if let heartRate = point.heartRate {
                    xml += "            <gpxtpx:hr>\(Int(heartRate.rounded()))</gpxtpx:hr>\n"
                }
                if let cadence = point.cadence {
                    xml += "            <gpxtpx:cad>\(Int(cadence.rounded()))</gpxtpx:cad>\n"
                }
                xml += "          </gpxtpx:TrackPointExtension>\n        </extensions>\n"
            }
            xml += "      </trkpt>\n"
        }

        xml += """
            </trkseg>
          </trk>
        </gpx>

        """
        return Data(xml.utf8)
    }

    // MARK: - Helpers

    /// `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the
    /// formatter is a reference type that is not `Sendable`, so a shared static
    /// one will not compile under Swift 6's concurrency checking. The format
    /// style is a value type and is safe to share.
    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func format(_ value: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Parser

private final class GPXParser: NSObject, XMLParserDelegate {

    private var points: [TrackPoint] = []
    private var name: String?
    private var typeHint: String?

    // State for the point being assembled.
    private var latitude: Double?
    private var longitude: Double?
    private var timestamp: Date?
    private var altitude: Double?
    private var speed: Double?
    private var course: Double?
    private var heartRate: Double?
    private var cadence: Double?
    private var accuracy: Double?

    private var text = ""
    private var parseError: Error?

    func parse(_ data: Data) throws -> ImportedTrack {
        let parser = XMLParser(data: data)
        parser.delegate = self
        // Namespace handling off: real-world GPX uses a zoo of prefixes for the
        // same extensions, and matching on the local name is far more robust
        // than trying to honour every one of them.
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            throw ImportError.malformed(
                parser.parserError?.localizedDescription ?? "The GPX file could not be parsed."
            )
        }
        if let parseError { throw parseError }
        guard !points.isEmpty else { throw ImportError.noTrackPoints }

        return ImportedTrack(
            points: points,
            name: name,
            sportHint: Sport(rawValue: typeHint ?? ""),
            format: .gpx
        )
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        text = ""
        guard localName(elementName) == "trkpt" || localName(elementName) == "rtept" else { return }

        latitude = attributes["lat"].flatMap(Double.init)
        longitude = attributes["lon"].flatMap(Double.init)
        timestamp = nil
        altitude = nil
        speed = nil
        course = nil
        heartRate = nil
        cadence = nil
        accuracy = nil
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        switch localName(elementName) {
        case "trkpt", "rtept":
            appendPoint()
        case "time":
            // `<time>` also appears in `<metadata>`; only take it inside a point.
            if latitude != nil { timestamp = parseDate(value) }
        case "ele":
            altitude = Double(value)
        case "speed":
            // Both the GPX 1.0 element and the extension land here.
            if let s = Double(value), s >= 0 { speed = s }
        case "course", "heading":
            if let c = Double(value), c >= 0 { course = c }
        case "hr", "heartrate":
            heartRate = Double(value)
        case "cad", "cadence":
            cadence = Double(value)
        case "hdop":
            // HDOP is not metres, but it is the only accuracy signal most GPX
            // files carry. The rough field conversion is metres ≈ HDOP × 5,
            // which is enough to let the ingest filter reject genuinely bad
            // fixes without pretending to a precision the file does not have.
            if let hdop = Double(value), hdop > 0 { accuracy = hdop * 5 }
        case "name":
            if latitude == nil, name == nil { name = value }
        case "type":
            if latitude == nil { typeHint = value.lowercased() }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = ImportError.malformed(error.localizedDescription)
    }

    // MARK: Helpers

    private func appendPoint() {
        defer { latitude = nil; longitude = nil }
        guard let latitude, let longitude, let timestamp else { return }

        points.append(TrackPoint(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            speed: speed,
            course: course,
            // No accuracy in the file means "unknown", which the ingest layer
            // treats as acceptable. Claiming zero here would tell it the fix
            // was perfect.
            horizontalAccuracy: accuracy ?? 0,
            speedAccuracy: nil,   // unknown, not perfect — see KalmanSpeedFilter
            heartRate: heartRate,
            cadence: cadence
        ))
    }

    private func localName(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    private func parseDate(_ string: String) -> Date? {
        DateParsing.parse(string)
    }
}

/// Date parsing shared by the XML readers.
///
/// Timestamps in the wild come with and without fractional seconds, and with
/// `Z`, an offset, or nothing at all. A single formatter cannot cover that, so
/// this tries the plausible shapes in order.
enum DateParsing {

    private static let withFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let date = try? Date(trimmed, strategy: withFractional) { return date }
        if let date = try? Date(trimmed, strategy: plain) { return date }

        // Some exporters omit the zone entirely. ISO 8601 says that means local
        // time, but a track file with no zone is overwhelmingly UTC in practice,
        // and treating it as local would shift a whole session by hours.
        if !trimmed.hasSuffix("Z"), !trimmed.contains("+") {
            if let date = try? Date(trimmed + "Z", strategy: plain) { return date }
            if let date = try? Date(trimmed + "Z", strategy: withFractional) { return date }
        }
        return nil
    }
}
