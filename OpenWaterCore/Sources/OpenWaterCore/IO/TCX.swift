import Foundation

/// TCX (Garmin Training Center Database) reading and writing.
///
/// TCX is more structured than GPX and, usefully, has speed in its *standard*
/// extension schema rather than as a convention — `Extensions/TPX/Speed` is
/// part of the published activity extension, so a TCX round-trip preserves
/// Doppler speed without relying on anyone's house style.
///
/// It also carries distance per trackpoint, which is worth reading: a device's
/// own cumulative distance comes from its internal fusion and is often better
/// than differencing the positions we were given, especially where the file has
/// been decimated.
public enum TCX {

    // MARK: - Reading

    public static func read(_ data: Data) throws -> ImportedTrack {
        try TCXParser().parse(data)
    }

    public static func read(contentsOf url: URL) throws -> ImportedTrack {
        try read(Data(contentsOf: url))
    }

    // MARK: - Writing

    public static func write(session: Session) -> Data {
        let sport = session.sport.tcxSport
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase
            xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
            xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Activities>
            <Activity Sport="\(sport)">
              <Id>\(GPX.iso8601.format(session.startDate))</Id>
              <Lap StartTime="\(GPX.iso8601.format(session.startDate))">
                <TotalTimeSeconds>\(GPX.format(session.duration, 1))</TotalTimeSeconds>
                <DistanceMeters>\(GPX.format(session.track.totalDistance, 2))</DistanceMeters>
                <MaximumSpeed>\(GPX.format(session.summary?.maxSpeed ?? 0, 3))</MaximumSpeed>
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>

        """

        let track = session.track
        for (index, point) in track.points.enumerated() {
            xml += "          <Trackpoint>\n"
            xml += "            <Time>\(GPX.iso8601.format(point.timestamp))</Time>\n"
            xml += "            <Position>\n"
            xml += "              <LatitudeDegrees>\(GPX.format(point.latitude, 7))</LatitudeDegrees>\n"
            xml += "              <LongitudeDegrees>\(GPX.format(point.longitude, 7))</LongitudeDegrees>\n"
            xml += "            </Position>\n"
            if let altitude = point.altitude {
                xml += "            <AltitudeMeters>\(GPX.format(altitude, 2))</AltitudeMeters>\n"
            }
            if index < track.cumulativeDistance.count {
                xml += "            <DistanceMeters>\(GPX.format(track.cumulativeDistance[index], 2))</DistanceMeters>\n"
            }
            if let heartRate = point.heartRate {
                xml += "            <HeartRateBpm><Value>\(Int(heartRate.rounded()))</Value></HeartRateBpm>\n"
            }
            if let cadence = point.cadence {
                xml += "            <Cadence>\(Int(cadence.rounded()))</Cadence>\n"
            }
            if let speed = point.speed {
                xml += "            <Extensions><ns3:TPX><ns3:Speed>\(GPX.format(speed, 3))</ns3:Speed></ns3:TPX></Extensions>\n"
            }
            xml += "          </Trackpoint>\n"
        }

        xml += """
                </Track>
              </Lap>
              <Creator xsi:type="Device_t">
                <Name>openWater</Name>
              </Creator>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>

        """
        return Data(xml.utf8)
    }
}

private extension Sport {
    /// TCX only defines Running, Biking and Other. Everything here is Other,
    /// which is honest — inventing a sport name would just fail validation in
    /// whatever reads the file next.
    var tcxSport: String { "Other" }
}

// MARK: - Parser

private final class TCXParser: NSObject, XMLParserDelegate {

    private var points: [TrackPoint] = []
    private var name: String?
    private var sportHint: Sport?

    private var inTrackpoint = false
    private var timestamp: Date?
    private var latitude: Double?
    private var longitude: Double?
    private var altitude: Double?
    private var distance: Double?
    private var speed: Double?
    private var heartRate: Double?
    private var cadence: Double?

    /// Some files nest `<Value>` inside `<HeartRateBpm>`; track the parent so a
    /// bare `<Value>` is attributed correctly.
    private var elementStack: [String] = []
    private var text = ""
    private var parseError: Error?

    func parse(_ data: Data) throws -> ImportedTrack {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false

        guard parser.parse() else {
            throw ImportError.malformed(
                parser.parserError?.localizedDescription ?? "The TCX file could not be parsed."
            )
        }
        if let parseError { throw parseError }
        guard !points.isEmpty else { throw ImportError.noTrackPoints }

        var warnings: [String] = []
        if !points.contains(where: { $0.speed != nil }) {
            warnings.append(
                "This file has no speed channel, so speeds were worked out from position changes. Peak figures will be less precise than a watch recording."
            )
        }

        return ImportedTrack(
            points: points,
            name: name,
            sportHint: sportHint,
            format: .tcx,
            warnings: warnings
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String]
    ) {
        let local = localName(elementName)
        elementStack.append(local)
        text = ""

        switch local {
        case "trackpoint":
            inTrackpoint = true
            timestamp = nil; latitude = nil; longitude = nil; altitude = nil
            distance = nil; speed = nil; heartRate = nil; cadence = nil
        case "activity":
            if let sport = attributes["Sport"] { sportHint = Sport(tcxName: sport) }
        default:
            break
        }
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
        let local = localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        defer { if elementStack.last == local { elementStack.removeLast() } }

        switch local {
        case "trackpoint":
            appendPoint()
            inTrackpoint = false
        case "time":
            if inTrackpoint { timestamp = DateParsing.parse(value) }
        case "latitudedegrees":
            latitude = Double(value)
        case "longitudedegrees":
            longitude = Double(value)
        case "altitudemeters":
            altitude = Double(value)
        case "distancemeters":
            if inTrackpoint { distance = Double(value) }
        case "speed":
            if let s = Double(value), s >= 0 { speed = s }
        case "cadence", "runcadence":
            cadence = Double(value)
        case "value":
            // Only meaningful inside HeartRateBpm.
            if elementStack.dropLast().last == "heartratebpm" {
                heartRate = Double(value)
            }
        case "name":
            if !inTrackpoint, name == nil, !value.isEmpty { name = value }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = ImportError.malformed(error.localizedDescription)
    }

    private func appendPoint() {
        guard let latitude, let longitude, let timestamp else { return }
        points.append(TrackPoint(
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            speed: speed,
            course: nil,
            horizontalAccuracy: 0,
            speedAccuracy: nil,   // unknown, not perfect — see KalmanSpeedFilter
            heartRate: heartRate,
            cadence: cadence
        ))
    }

    private func localName(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }
}

private extension Sport {
    /// TCX's sport vocabulary is tiny, so this only ever produces a weak hint.
    init?(tcxName: String) {
        switch tcxName.lowercased() {
        case "running", "biking": return nil   // definitely not one of ours
        default: return nil
        }
    }
}
