import Foundation
import OpenWaterCore
import SwiftUI

/// The forecaster's own words.
///
/// NWS coastal offices write a Surf Zone Forecast by hand — surf heights
/// and rip current risk as a human judged them, not as a grid computed
/// them. This card quotes that product for the beach zone the point sits
/// in, named and dated, and is silently absent everywhere the product does
/// not exist — which is everywhere outside a US coastal office's patch.
struct SurfZoneForecast: Equatable {

    /// "National Weather Service New York NY" — the office's own byline.
    let office: String
    /// The zone's human name: "Kings (Brooklyn)", with the beach list when
    /// the office writes one.
    let area: String?
    let issued: Date
    /// The zone segment's forecast text, verbatim from the first day
    /// section to the categories footer.
    let text: String
}

extension NationalWeatherService {

    /// One remembered answer per ~10 km for half an hour — the product is
    /// issued about twice a day, and `ForecastCache` cannot carry the
    /// User-Agent this API requires, so the memory does the caching here.
    /// Nil answers are remembered too: an inland point asking every panel
    /// open would otherwise hammer an endpoint that will never say yes.
    @MainActor private static var surfZoneMemory: [String: (at: Date, value: SurfZoneForecast?)] = [:]

    @MainActor
    static func surfZone(at coordinate: Geo.Coordinate) async -> SurfZoneForecast? {
        let key = String(format: "%.1f,%.1f", coordinate.latitude, coordinate.longitude)
        if let held = surfZoneMemory[key], Date().timeIntervalSince(held.at) < 1800 {
            return held.value
        }
        let fetched = await fetchSurfZone(at: coordinate)
        surfZoneMemory[key] = (Date(), fetched)
        return fetched
    }

    private static func fetchSurfZone(at coordinate: Geo.Coordinate) async -> SurfZoneForecast? {
        // The point knows its office and its forecast zone; the zone code
        // is what picks this beach's segment out of an office-wide product.
        struct Points: Decodable {
            struct Properties: Decodable {
                let cwa: String?
                let forecastZone: String?
            }
            let properties: Properties?
        }
        guard let pointsURL = URL(string: String(
                format: "https://api.weather.gov/points/%.4f,%.4f",
                coordinate.latitude, coordinate.longitude)),
              let pointsData = await get(pointsURL),
              let points = (try? JSONDecoder().decode(Points.self, from: pointsData))?.properties,
              let office = points.cwa
        else { return nil }
        let zoneCode = points.forecastZone.flatMap { URL(string: $0)?.lastPathComponent }

        struct ProductList: Decodable {
            struct Item: Decodable {
                let id: String
                let issuanceTime: String?
            }
            let graph: [Item]?
            enum CodingKeys: String, CodingKey { case graph = "@graph" }
        }
        guard let listURL = URL(string: "https://api.weather.gov/products/types/SRF/locations/\(office)"),
              let listData = await get(listURL, accept: "application/ld+json"),
              let latest = (try? JSONDecoder().decode(ProductList.self, from: listData))?.graph?.first
        else { return nil }

        struct Product: Decodable {
            let productText: String?
            let issuanceTime: String?
        }
        guard let productURL = URL(string: "https://api.weather.gov/products/\(latest.id)"),
              let productData = await get(productURL, accept: "application/ld+json"),
              let product = try? JSONDecoder().decode(Product.self, from: productData),
              let text = product.productText
        else { return nil }

        let issued = (product.issuanceTime ?? latest.issuanceTime)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return parseSurfZone(product: text, issued: issued, zone: zoneCode)
    }

    /// The product is one text for the whole office, zone blocks separated
    /// by `$$`: a zone-code line, the area's name, sometimes the beaches it
    /// covers, then the day sections. This picks the block whose codes name
    /// the point's own zone — first block as the fallback, because a
    /// forecast for the neighbouring beach beats none — and quotes it up to
    /// the `&&` footer where the office explains its categories.
    static func parseSurfZone(product: String, issued: Date, zone: String?) -> SurfZoneForecast? {
        let office = product
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("National Weather Service") }
            ?? "National Weather Service"

        let blocks = product.components(separatedBy: "$$")
        // A zone block opens with codes like "NYZ075-180900-": two state
        // letters, a Z, three digits. Spelled as character checks rather
        // than a regex, so the shape being matched is the shape you read.
        func isZoneCodeLine(_ line: String) -> Bool {
            let head = Array(line.prefix(6))
            guard head.count == 6 else { return false }
            return head[0].isLetter && head[0].isUppercase
                && head[1].isLetter && head[1].isUppercase
                && head[2] == "Z"
                && head[3].isNumber && head[4].isNumber && head[5].isNumber
        }
        func isZoneBlock(_ block: String) -> Bool {
            block.components(separatedBy: .newlines).contains(where: isZoneCodeLine)
        }
        guard let block = blocks.first(where: { candidate in
            guard isZoneBlock(candidate) else { return false }
            guard let zone else { return true }
            return candidate.contains(zone) || blocks.allSatisfy { !$0.contains(zone) }
        }) else { return nil }

        var lines = block.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: isZoneCodeLine) else { return nil }
        lines = Array(lines[start...])

        // The name is the line after the codes, shorn of its trailing
        // hyphen; the beach list rides along when the office writes one.
        var area = lines[safe: 1]?.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        if let beaches = lines[safe: 2], beaches.hasPrefix("Including") {
            area = [area, beaches.trimmingCharacters(in: .whitespaces)]
                .compactMap { $0 }.joined(separator: " — ")
        }

        guard let bodyStart = lines.firstIndex(where: { $0.hasPrefix(".") }) else { return nil }
        var body = lines[bodyStart...].joined(separator: "\n")
        if let footer = body.range(of: "&&") {
            body = String(body[..<footer.lowerBound])
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        return SurfZoneForecast(office: office, area: area, issued: issued, text: trimmed)
    }
}

/// The quote itself: the office's byline, the beach it covers, and the
/// forecaster's text in the product's own column alignment — monospaced,
/// because the dot leaders are the layout.
struct SurfZoneCard: View {

    let forecast: SurfZoneForecast
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "quote.opening")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Surf zone forecast")
                        .font(.caption.weight(.bold))
                    Text("\(forecast.office) · \(forecast.issued.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let area = forecast.area {
                        Text(area)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(forecast.text)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(expanded ? nil : 12)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                Text(expanded ? "Less" : "The whole forecast")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            Text("Written by a forecaster, not a model — the one hand-made forecast on this screen.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
