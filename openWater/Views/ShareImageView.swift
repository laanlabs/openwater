import CoreLocation
import OpenWaterCore
import SwiftUI

/// Turn a session into a picture worth posting.
///
/// This is the share people actually use. A link is for someone who wants to
/// study the session; an image is for the group chat, and it has to say what
/// happened without being tapped: the shape of the track, the top speed, the
/// distance. Everything is rendered on device — no server, nothing uploaded,
/// and the rider can look at exactly what they are about to send.
struct ShareImageView: View {

    let session: Session
    let summary: SessionSummary
    let title: String

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var shape: Shape = .portrait
    @State private var theme: Theme = .map
    @State private var mapImage: UIImage?
    @State private var rendered: URL?

    enum Shape: String, CaseIterable, Identifiable {
        case square = "Square"
        case portrait = "Portrait"
        case landscape = "Landscape"

        var id: String { rawValue }

        /// Instagram's three sizes, which is what everything else follows.
        var pixelSize: CGSize {
            switch self {
            case .square: CGSize(width: 1080, height: 1080)
            case .portrait: CGSize(width: 1080, height: 1350)
            case .landscape: CGSize(width: 1350, height: 1080)
            }
        }

        var ratio: CGFloat { pixelSize.width / pixelSize.height }
    }

    enum Theme: String, CaseIterable, Identifiable {
        case map = "Map"
        case night = "Night"
        case clean = "Clean"

        var id: String { rawValue }
    }

    private var samples: [PreviewSample] {
        // The card is drawn from the session in hand rather than the stored
        // preview column, so it gets the full-resolution shape.
        let track = session.track
        let step = max(1, track.count / 900)
        return stride(from: 0, to: track.count, by: step).compactMap { index in
            let point = track.points[index]
            guard point.hasValidPosition else { return nil }
            return PreviewSample(coordinate: point.clCoordinate, speed: track.speed[index])
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    card
                        .aspectRatio(shape.ratio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                Picker("Theme", selection: $theme) {
                    ForEach(Theme.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                Picker("Shape", selection: $shape) {
                    ForEach(Shape.allCases) { option in Text(option.rawValue).tag(option) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                if let rendered {
                    ShareLink(item: rendered, preview: SharePreview(title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 20)
                } else {
                    ProgressView()
                        .frame(height: 52)
                }
            }
            .padding(.bottom, 12)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Share Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task(id: "\(theme.rawValue)-\(shape.rawValue)") {
                await prepare()
            }
        }
    }

    // MARK: - The card

    @ViewBuilder
    private var card: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / shape.pixelSize.width

            // Map above, numbers below, rather than numbers floating over the
            // map. Partly because text over a pale track is unreadable wherever
            // the scrim is put — and partly because Apple's map attribution
            // sits in the corner of a snapshot and must stay visible, which a
            // full-bleed layout with a title over it does not manage.
            let mapHeight = proxy.size.height * (1 - panelFraction)

            VStack(spacing: 0) {
                ZStack {
                    background

                    if theme == .map, let mapImage {
                        // Sized and clipped here rather than left to fill: an
                        // aspect-filled image inflates the stack around it, and
                        // everything else in the stack — the date, the map
                        // attribution — gets pushed outside the card.
                        Image(uiImage: mapImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: mapHeight)
                            .clipped()
                    } else {
                        SpeedTrackCanvas(samples: samples, scale: SpeedScale(speeds: samples.map(\.speed)), lineWidth: 4)
                            .padding(40 * scale)
                    }

                    VStack {
                        HStack {
                            Text(session.startDate.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Label(session.sport.displayName, systemImage: session.sport.symbolName)
                        }
                        .font(.system(size: 34 * scale, weight: .semibold))
                        .foregroundStyle(theme == .night ? .white.opacity(0.85) : Color(red: 0.05, green: 0.12, blue: 0.23).opacity(0.75))
                        .padding(44 * scale)
                        Spacer()
                    }
                }
                .frame(height: mapHeight)
                .clipped()

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8 * scale) {
                        Image(systemName: "water.waves")
                        Text("open")
                            .fontWeight(.bold)
                        + Text("Water")
                    }
                    .font(.system(size: 40 * scale))
                    .foregroundStyle(foreground.opacity(0.9))

                    Text(title)
                        .font(.system(size: 72 * scale, weight: .bold))
                        .foregroundStyle(foreground)
                        .lineLimit(1)
                        .padding(.top, 6 * scale)

                    HStack(alignment: .top, spacing: 0) {
                        cardStat("Max Speed", Format.speed(summary.maxSpeed, unit: settings.units.speed, decimals: 2, includeSymbol: false), settings.units.speed.symbol, scale)
                        cardStat("Avg speed", Format.speed(summary.averageMovingSpeed, unit: settings.units.speed, decimals: 2, includeSymbol: false), settings.units.speed.symbol, scale)
                        cardStat("Distance", Format.distance(summary.distance, unit: settings.units.distance, includeSymbol: false), settings.units.distance.symbol, scale)
                    }
                    .padding(.top, 22 * scale)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(44 * scale)
                .background(panelBackground)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    /// How much of the card the numbers take. Fixed rather than intrinsic,
    /// because a flexible map above an intrinsic panel lets the map win the
    /// layout and squeeze the numbers off the bottom of the card.
    private var panelFraction: CGFloat {
        switch shape {
        case .square: 0.30
        case .portrait: 0.26
        case .landscape: 0.32
        }
    }

    private func cardStat(_ label: String, _ value: String, _ unit: String, _ scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            Text("\(label) (\(unit))")
                .font(.system(size: 30 * scale))
                .foregroundStyle(foreground.opacity(0.75))
            BigNumber(value, size: 62 * scale)
                .foregroundStyle(foreground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var background: some View {
        Group {
            switch theme {
            case .map:
                Color(.secondarySystemBackground)
            case .night:
                LinearGradient(
                    colors: [Color(red: 0.04, green: 0.09, blue: 0.20), Color(red: 0.02, green: 0.04, blue: 0.09)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            case .clean:
                Color(red: 0.96, green: 0.97, blue: 0.98)
            }
        }
    }

    private var foreground: Color {
        theme == .clean ? Color(red: 0.05, green: 0.12, blue: 0.23) : .white
    }

    /// The panel the numbers sit on. Solid, so the type is legible whatever the
    /// track happens to look like that day.
    private var panelBackground: some View {
        Group {
            switch theme {
            case .map:
                LinearGradient(
                    colors: [Color(red: 0.06, green: 0.13, blue: 0.25), Color(red: 0.03, green: 0.07, blue: 0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            case .night:
                Color(red: 0.02, green: 0.04, blue: 0.09)
            case .clean:
                Color.white
            }
        }
    }

    // MARK: - Rendering

    /// Render the card to a PNG on disk, which is what `ShareLink` needs to
    /// hand a real file to Messages, Instagram or Photos.
    @MainActor
    private func prepare() async {
        rendered = nil

        if theme == .map {
            mapImage = await TrackThumbnailCache.shared.image(
                id: session.id,
                samples: samples,
                // Rendered at the map area's own shape, so nothing has to be
                // cropped later — a crop takes Apple's map attribution with it.
                size: CGSize(
                    width: shape.pixelSize.width / 3,
                    height: shape.pixelSize.height * (1 - panelFraction) / 3
                ),
                style: settings.mapStyle,
                scale: 3
            )
        }

        let renderer = ImageRenderer(
            content: card
                .frame(width: shape.pixelSize.width, height: shape.pixelSize.height)
                .environment(settings)
        )
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openWater-\(session.id.uuidString.prefix(8)).png")
        try? data.write(to: url, options: .atomic)
        rendered = url
    }
}

/// The track, speed-coloured, drawn to fit whatever box it is given.
///
/// A `Canvas` rather than a `Shape`: a single path can only take one colour,
/// and the colour is half the information — which parts of the session were
/// fast is exactly what a rider wants to show off.
struct SpeedTrackCanvas: View {

    let samples: [PreviewSample]
    let scale: SpeedScale
    var lineWidth: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }

            var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
            for sample in samples {
                minLat = min(minLat, sample.coordinate.latitude)
                maxLat = max(maxLat, sample.coordinate.latitude)
                minLon = min(minLon, sample.coordinate.longitude)
                maxLon = max(maxLon, sample.coordinate.longitude)
            }

            // Longitude degrees shrink with latitude; ignoring that squashes a
            // session at 60° N into something its rider would not recognise.
            let squeeze = cos(minLat * .pi / 180)
            let latitudeSpan = max(maxLat - minLat, 1e-6)
            let longitudeSpan = max((maxLon - minLon) * squeeze, 1e-6)
            let zoom = min(size.width / longitudeSpan, size.height / latitudeSpan)
            let originX = (size.width - longitudeSpan * zoom) / 2
            let originY = (size.height - latitudeSpan * zoom) / 2

            func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
                CGPoint(
                    x: originX + (coordinate.longitude - minLon) * squeeze * zoom,
                    y: originY + (maxLat - coordinate.latitude) * zoom
                )
            }

            for index in 1..<samples.count {
                var path = Path()
                path.move(to: project(samples[index - 1].coordinate))
                path.addLine(to: project(samples[index].coordinate))
                let speed = max(samples[index - 1].speed, samples[index].speed)
                context.stroke(
                    path,
                    with: .color(Color(speedRampColour(speed, scale: scale))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}
