import Foundation

/// A minimal, read-only FIT decoder.
///
/// FIT is what every serious GPS watch actually exports — Garmin, Suunto, Coros
/// and Vakaros all write it — and it is the only common format that reliably
/// carries **Doppler speed** and **per-fix GPS accuracy**. GPX from the same
/// device usually has both stripped out. So supporting FIT is the difference
/// between analysing a Garmin session properly and guessing at it.
///
/// The format is a self-describing binary stream: *definition* messages declare
/// the shape of the records that follow, and *data* messages carry values in
/// exactly that shape. That means a decoder does not need to know the whole
/// vendor profile — it needs to parse the container, then pick out the handful
/// of field numbers it cares about and skip everything else by its declared
/// size. This one does exactly that, which is why it is a few hundred lines
/// rather than a few thousand.
///
/// **Read-only, on purpose.** Parsing a file a rider already owns is
/// straightforward. Writing one means asserting conformance to a vendor
/// profile, which is a licensing question rather than a technical one, so it is
/// deliberately out of scope — see `FileFormat.writable`.
public enum FIT {

    // MARK: - Public

    public static func read(_ data: Data) throws -> ImportedTrack {
        var decoder = Decoder(data: data)
        let records = try decoder.decode()

        guard !records.isEmpty else { throw ImportError.noTrackPoints }

        var warnings = decoder.warnings
        if !records.contains(where: { $0.speed != nil }) {
            warnings.append(
                "This FIT file has no speed channel, so speeds were derived from positions."
            )
        }

        return ImportedTrack(
            points: records,
            name: nil,
            sportHint: decoder.sportHint,
            format: .fit,
            warnings: warnings
        )
    }

    public static func read(contentsOf url: URL) throws -> ImportedTrack {
        try read(Data(contentsOf: url))
    }

    // MARK: - Constants

    /// FIT counts seconds from 1989-12-31T00:00:00Z, not from the Unix epoch.
    static let epochOffset: TimeInterval = 631_065_600

    /// Latitude and longitude are stored as *semicircles*: a signed 32-bit
    /// integer covering ±180°, so one semicircle is 180 / 2³¹ degrees.
    static let degreesPerSemicircle = 180.0 / 2147483648.0

    enum GlobalMessage: UInt16 {
        case fileID = 0
        case session = 18
        case lap = 19
        case record = 20
        case sport = 12
    }

    /// The `record` message fields worth extracting.
    enum RecordField: UInt8 {
        case positionLat = 0
        case positionLong = 1
        case altitude = 2
        case heartRate = 3
        case cadence = 4
        case distance = 5
        case speed = 6
        case temperature = 13
        case gpsAccuracy = 31
        case enhancedSpeed = 73
        case enhancedAltitude = 78
        case timestamp = 253
    }

    // MARK: - Base types

    /// FIT base types. The high bit marks an endian-sensitive type; the low
    /// nibble is the type number.
    struct BaseType {
        let raw: UInt8

        var size: Int {
            switch raw & 0x1F {
            case 0x00, 0x01, 0x02, 0x0A, 0x0D: 1     // enum, sint8, uint8, uint8z, byte
            case 0x03, 0x04, 0x0B: 2                 // sint16, uint16, uint16z
            case 0x05, 0x06, 0x08, 0x0C: 4           // sint32, uint32, float32, uint32z
            case 0x09, 0x0E, 0x0F, 0x10: 8           // float64, sint64, uint64, uint64z
            case 0x07: 1                             // string — variable, size comes from the definition
            default: 1
            }
        }

        var isSigned: Bool {
            switch raw & 0x1F {
            case 0x01, 0x03, 0x05, 0x0E: true
            default: false
            }
        }

        /// The reserved "no value here" pattern for this type. Emitting it as a
        /// real number is the classic FIT bug — a missing heart rate becomes
        /// 255 bpm, a missing position becomes a point off the coast of Africa.
        var invalidValue: UInt64 {
            switch raw & 0x1F {
            case 0x00, 0x02, 0x0D: 0xFF
            case 0x01: 0x7F
            case 0x03: 0x7FFF
            case 0x04: 0xFFFF
            case 0x05: 0x7FFF_FFFF
            case 0x06, 0x08: 0xFFFF_FFFF
            case 0x0A: 0x00
            case 0x0B: 0x0000
            case 0x0C: 0x0000_0000
            case 0x0E: 0x7FFF_FFFF_FFFF_FFFF
            case 0x0F, 0x09: 0xFFFF_FFFF_FFFF_FFFF
            case 0x10: 0x0000_0000_0000_0000
            default: 0xFF
            }
        }
    }

    struct FieldDefinition {
        let number: UInt8
        let size: Int
        let baseType: BaseType
    }

    struct MessageDefinition {
        let globalNumber: UInt16
        let isBigEndian: Bool
        let fields: [FieldDefinition]
        let developerFieldSize: Int

        var totalSize: Int {
            fields.reduce(0) { $0 + $1.size } + developerFieldSize
        }
    }

    // MARK: - Decoder

    struct Decoder {
        let data: Data
        var offset: Int = 0
        var warnings: [String] = []
        var sportHint: Sport?

        /// Definitions are addressed by a 4-bit "local message type" that gets
        /// redefined as the file goes along, so this map is mutable state, not a
        /// lookup table built up front.
        private var definitions: [UInt8: MessageDefinition] = [:]

        init(data: Data) {
            self.data = data
        }

        mutating func decode() throws -> [TrackPoint] {
            let dataEnd = try readHeader()
            var points: [TrackPoint] = []
            points.reserveCapacity(4096)

            while offset < dataEnd, offset < data.count {
                guard let header = readByte() else { break }

                if header & 0x80 != 0 {
                    // Compressed timestamp header: the low 5 bits are a time
                    // offset from the last full timestamp, and the local message
                    // type is in bits 5–6.
                    let localType = (header >> 5) & 0x03
                    guard let definition = definitions[localType] else {
                        // Data before its definition means the stream is not
                        // parseable from here on — there is no way to know how
                        // many bytes to skip.
                        throw ImportError.malformed("FIT data message with no definition")
                    }
                    if let point = try readDataMessage(definition) { points.append(point) }
                } else if header & 0x40 != 0 {
                    // Definition message.
                    let localType = header & 0x0F
                    let hasDeveloperFields = header & 0x20 != 0
                    definitions[localType] = try readDefinition(hasDeveloperFields: hasDeveloperFields)
                } else {
                    let localType = header & 0x0F
                    guard let definition = definitions[localType] else {
                        throw ImportError.malformed("FIT data message with no definition")
                    }
                    if let point = try readDataMessage(definition) { points.append(point) }
                }
            }

            return points
        }

        // MARK: Header

        /// Returns the offset at which the data section ends.
        private mutating func readHeader() throws -> Int {
            guard data.count >= 14 else { throw ImportError.truncated }

            let headerSize = Int(data[data.startIndex])
            guard headerSize == 12 || headerSize == 14 else {
                throw ImportError.malformed("Unexpected FIT header size \(headerSize)")
            }

            let protocolVersion = Int(data[data.startIndex + 1] >> 4)
            guard protocolVersion <= 2 else {
                throw ImportError.unsupportedFITVersion(protocolVersion)
            }

            let signature = data[data.startIndex + 8 ..< data.startIndex + 12]
            guard signature.elementsEqual([0x2E, 0x46, 0x49, 0x54]) else {
                throw ImportError.malformed("Missing .FIT signature")
            }

            let dataSize = Int(readUInt32(at: data.startIndex + 4, bigEndian: false))
            offset = headerSize

            // Trust the declared size, but never past the end of the buffer — a
            // truncated download has a valid header and a short body, and
            // reading past it would crash rather than degrade.
            let declaredEnd = headerSize + dataSize
            if declaredEnd > data.count {
                warnings.append("The file appears to be truncated; openWater read as much as it could.")
                return data.count
            }
            return declaredEnd
        }

        // MARK: Definitions

        private mutating func readDefinition(hasDeveloperFields: Bool) throws -> MessageDefinition {
            guard let _ = readByte(),                      // reserved
                  let architecture = readByte(),
                  let globalLow = readByte(),
                  let globalHigh = readByte(),
                  let fieldCount = readByte() else { throw ImportError.truncated }

            let isBigEndian = architecture == 1
            let globalNumber = isBigEndian
                ? (UInt16(globalLow) << 8) | UInt16(globalHigh)
                : (UInt16(globalHigh) << 8) | UInt16(globalLow)

            var fields: [FieldDefinition] = []
            fields.reserveCapacity(Int(fieldCount))
            for _ in 0..<fieldCount {
                guard let number = readByte(),
                      let size = readByte(),
                      let baseType = readByte() else { throw ImportError.truncated }
                fields.append(FieldDefinition(
                    number: number,
                    size: Int(size),
                    baseType: BaseType(raw: baseType)
                ))
            }

            // Developer fields carry app-specific data we do not interpret, but
            // their sizes still have to be accounted for or every subsequent
            // message would be misaligned.
            var developerSize = 0
            if hasDeveloperFields {
                guard let developerCount = readByte() else { throw ImportError.truncated }
                for _ in 0..<developerCount {
                    guard let _ = readByte(),          // field number
                          let size = readByte(),
                          let _ = readByte() else { throw ImportError.truncated }
                    developerSize += Int(size)
                }
            }

            return MessageDefinition(
                globalNumber: globalNumber,
                isBigEndian: isBigEndian,
                fields: fields,
                developerFieldSize: developerSize
            )
        }

        // MARK: Data

        private mutating func readDataMessage(_ definition: MessageDefinition) throws -> TrackPoint? {
            let messageStart = offset
            defer {
                // Always advance by the declared size, whatever happened inside.
                // Alignment is what keeps the rest of the file readable.
                offset = messageStart + definition.totalSize
            }
            guard messageStart + definition.totalSize <= data.count else {
                offset = data.count
                return nil
            }

            guard definition.globalNumber == GlobalMessage.record.rawValue else {
                if definition.globalNumber == GlobalMessage.sport.rawValue {
                    readSportHint(definition, from: messageStart)
                }
                return nil
            }

            var cursor = messageStart
            var timestamp: Date?
            var latitude: Double?
            var longitude: Double?
            var altitude: Double?
            var speed: Double?
            var heartRate: Double?
            var cadence: Double?
            var accuracy: Double?

            for field in definition.fields {
                let value = readScalar(at: cursor, field: field, bigEndian: definition.isBigEndian)
                cursor += field.size

                guard let value else { continue }
                switch RecordField(rawValue: field.number) {
                case .timestamp:
                    timestamp = Date(timeIntervalSince1970: value + FIT.epochOffset)
                case .positionLat:
                    latitude = value * FIT.degreesPerSemicircle
                case .positionLong:
                    longitude = value * FIT.degreesPerSemicircle
                case .altitude:
                    // scale 5, offset 500
                    altitude = value / 5 - 500
                case .enhancedAltitude:
                    altitude = value / 5 - 500
                case .speed:
                    speed = value / 1000            // scale 1000, m/s
                case .enhancedSpeed:
                    // Enhanced speed has more headroom and wins where both are
                    // present — it is the field Garmin populates for fast sports.
                    speed = value / 1000
                case .heartRate:
                    heartRate = value
                case .cadence:
                    cadence = value
                case .gpsAccuracy:
                    accuracy = value                // metres
                default:
                    break
                }
            }

            guard let timestamp, let latitude, let longitude else { return nil }
            // Records with no fix carry the invalid pattern, filtered above, but
            // a zero-zero position is another way devices say "no fix".
            guard !(latitude == 0 && longitude == 0) else { return nil }

            return TrackPoint(
                timestamp: timestamp,
                latitude: latitude,
                longitude: longitude,
                altitude: altitude,
                speed: speed,
                course: nil,
                horizontalAccuracy: accuracy ?? 0,
                speedAccuracy: nil,   // unknown, not perfect — see KalmanSpeedFilter
                heartRate: heartRate,
                cadence: cadence
            )
        }

        private mutating func readSportHint(_ definition: MessageDefinition, from start: Int) {
            var cursor = start
            for field in definition.fields {
                if field.number == 0, let value = readScalar(
                    at: cursor, field: field, bigEndian: definition.isBigEndian
                ) {
                    sportHint = Sport(fitSportID: Int(value))
                }
                cursor += field.size
            }
        }

        // MARK: Primitives

        /// Read one field as a `Double`, or `nil` when it holds the invalid
        /// pattern or is a type we do not interpret numerically.
        private func readScalar(at index: Int, field: FieldDefinition, bigEndian: Bool) -> Double? {
            let typeSize = field.baseType.size
            guard typeSize > 0, index + typeSize <= data.count else { return nil }
            // Arrays and strings are skipped: the size in the definition exceeds
            // one element, and none of the fields we want are arrays.
            guard field.size == typeSize else { return nil }

            let raw: UInt64
            switch typeSize {
            case 1: raw = UInt64(data[data.startIndex + index])
            case 2: raw = UInt64(readUInt16(at: data.startIndex + index, bigEndian: bigEndian))
            case 4: raw = UInt64(readUInt32(at: data.startIndex + index, bigEndian: bigEndian))
            case 8: raw = readUInt64(at: data.startIndex + index, bigEndian: bigEndian)
            default: return nil
            }

            guard raw != field.baseType.invalidValue else { return nil }

            if field.baseType.isSigned {
                switch typeSize {
                case 1: return Double(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
                case 2: return Double(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
                case 4: return Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
                case 8: return Double(Int64(bitPattern: raw))
                default: return nil
                }
            }
            // float32 / float64 are bit patterns, not integers.
            if field.baseType.raw & 0x1F == 0x08 {
                return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
            }
            if field.baseType.raw & 0x1F == 0x09 {
                return Double(bitPattern: raw)
            }
            return Double(raw)
        }

        private mutating func readByte() -> UInt8? {
            guard offset < data.count else { return nil }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        private func readUInt16(at index: Int, bigEndian: Bool) -> UInt16 {
            let a = UInt16(data[index]), b = UInt16(data[index + 1])
            return bigEndian ? (a << 8) | b : (b << 8) | a
        }

        private func readUInt32(at index: Int, bigEndian: Bool) -> UInt32 {
            var result: UInt32 = 0
            for i in 0..<4 {
                let byte = UInt32(data[index + i])
                result |= bigEndian ? byte << (8 * (3 - i)) : byte << (8 * i)
            }
            return result
        }

        private func readUInt64(at index: Int, bigEndian: Bool) -> UInt64 {
            var result: UInt64 = 0
            for i in 0..<8 {
                let byte = UInt64(data[index + i])
                result |= bigEndian ? byte << (8 * (7 - i)) : byte << (8 * i)
            }
            return result
        }
    }
}

private extension Sport {
    /// FIT's sport enum. Only the ones that map to something we handle; anything
    /// else leaves the sport unset so the rider is asked rather than guessed at.
    init?(fitSportID: Int) {
        switch fitSportID {
        case 24: self = .windsurf      // kitesurfing in some profiles, wind sports generally
        case 32: self = .sail          // sailing
        case 37: self = .sup           // stand up paddleboarding
        case 41: self = .kayak         // kayaking
        case 38: self = .other         // surfing
        default: return nil
        }
    }
}
