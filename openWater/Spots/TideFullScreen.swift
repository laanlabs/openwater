import OpenWaterCore
import SwiftUI

/// The tide, full screen, read against a line fixed to the middle.
///
/// The card version has to fit a curve for a day or more into the width of a
/// phone, which is enough to see the shape and not enough to answer "what is
/// it doing at four". This is the same interaction as the model comparison:
/// the reading line does not move, the water does, and whatever sits under
/// the line is what the header reads out.
struct TideFullScreen: View {

    let curve: TideCurve
    let title: String

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    /// The point under the reading line.
    @State private var probe: Int?
    @State private var scroll = ScrollPosition()
    @State private var hasLanded = false
    @State private var isGivingFeedback = false

    /// Screen width per hourly sample.
    ///
    /// Widened with the horizon: four days at six points an hour fits in
    /// about two screens, which makes a scrollable chart that barely needs
    /// scrolling and crushes each tide into a spike. Twelve gives a day about
    /// a screen and a half, so the shape is legible and the scroll is worth
    /// the gesture.
    private static let pointWidth: CGFloat = 12

    private var zone: TimeZone { curve.timeZone ?? .current }

    private var span: (low: Double, high: Double) {
        let low = curve.low, high = curve.high
        let pad = max(0.1, (high - low) * 0.18)
        return (low - pad, high + pad)
    }

    /// The sample nearest now, which is where the view opens.
    private var nowIndex: Int? {
        let moment = Date()
        return curve.points.indices.min {
            abs(curve.points[$0].at.timeIntervalSince(moment))
                < abs(curve.points[$1].at.timeIntervalSince(moment))
        }
    }

    private var reading: TideCurve.Point? {
        probe.flatMap { curve.points[safe: $0] } ?? curve.now
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Half the screen. A tide curve is a shape, not a plot somebody
            // reads values off pixel by pixel — given the whole screen it
            // just made the same two humps larger, and pushed the reading it
            // exists to give out of the eye's way at the top.
            chart
                .containerRelativeFrame(.vertical) { height, _ in height * 0.5 }
            footer
            Spacer(minLength: 0)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $isGivingFeedback) {
            AppFeedbackSheet(screen: "Tide chart")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                Spacer()
                Text(title)
                    .font(.headline)
                Spacer()
                // The slot on the right was a spacer keeping the title
                // centred against the back button. It is the same size and
                // the same shape as a control, so it may as well be one.
                Button { isGivingFeedback = true } label: {
                    Image(systemName: "ladybug")
                        .font(.headline)
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Send feedback about the tide chart")
            }

            if let reading {
                Text(reading.at.formatted(.dateTime.weekday(.abbreviated)
                    .month(.abbreviated).day().hour().minute()))
                    .font(.subheadline.weight(.semibold))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.height(reading.metres, unit: settings.units.distance))
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                    Text(rising(at: probe) ? "rising" : "falling")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }

    private var chart: some View {
        GeometryReader { outer in
            let height = outer.size.height
            let width = CGFloat(curve.points.count) * Self.pointWidth

            ZStack {
                GeometryReader { viewport in
                    let half = viewport.size.width / 2
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            TideShape(points: curve.points, span: span)
                                .fill(LinearGradient(
                                    colors: [.teal.opacity(0.45), .teal.opacity(0.05)],
                                    startPoint: .top, endPoint: .bottom))
                            TideShape(points: curve.points, span: span, lineOnly: true)
                                .stroke(.teal, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                            dayRules(height: height)

                            // Now, in the water's own coordinates, so it
                            // scrolls with the curve. The reading line is
                            // fixed to the screen; this one marks the moment.
                            if let now = nowIndex {
                                Rectangle()
                                    .fill(Color.orange)
                                    .frame(width: 2, height: height)
                                    .offset(x: CGFloat(now) * Self.pointWidth)
                            }
                        }
                        .frame(width: width, height: height)
                        // One layer instead of re-rasterising the curve on
                        // every frame of a drag.
                        .drawingGroup()
                        .padding(.horizontal, half)
                    }
                    .scrollPosition($scroll)
                    // Transformed to the sample index rather than to the raw
                    // offset: the action runs only when the value changes, and
                    // the header can only read out one sample. Reported as a
                    // distance it fired on every pixel of a drag and rebuilt
                    // this whole view each time.
                    .onScrollGeometryChange(for: Int.self) { geometry in
                        let index = Int(geometry.contentOffset.x / Self.pointWidth + 0.5)
                        return min(max(0, index), max(0, curve.points.count - 1))
                    } action: { _, index in
                        probe = index
                    }
                    .onChange(of: curve.points.count, initial: true) { _, _ in
                        guard !hasLanded, let now = nowIndex else { return }
                        hasLanded = true
                        scroll.scrollTo(x: CGFloat(now) * Self.pointWidth)
                    }
                }

                // Fixed to the screen, not to the water.
                Rectangle()
                    .fill(Color.primary.opacity(0.45))
                    .frame(width: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    /// A rule at each midnight, so a curve two days long is readable as days.
    @ViewBuilder
    private func dayRules(height: CGFloat) -> some View {
        var calendar = Calendar.current
        let _ = calendar.timeZone = zone
        let midnights = curve.points.indices.filter { index in
            guard index > 0 else { return false }
            return !calendar.isDate(curve.points[index].at,
                                    inSameDayAs: curve.points[index - 1].at)
        }

        ForEach(midnights, id: \.self) { index in
            let x = CGFloat(index) * Self.pointWidth
            Rectangle()
                .fill(Color(.systemGray3).opacity(0.6))
                .frame(width: 1, height: height)
                .offset(x: x)
            Text(curve.points[index].at.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .offset(x: x + 4, y: 4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label {
                    Text("Now").font(.caption2)
                } icon: {
                    Rectangle().fill(.orange).frame(width: 10, height: 2)
                }
                Label {
                    Text("Reading").font(.caption2)
                } icon: {
                    Rectangle().fill(Color.primary.opacity(0.45)).frame(width: 10, height: 2)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)

            Text("Heights are against mean sea level, so they will not match NOAA's, "
                 + "which are against mean lower low water. Scroll the water under the line.")
        }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
    }

    /// Whether the water is coming in at the sample under the line.
    private func rising(at index: Int?) -> Bool {
        guard let index, let here = curve.points[safe: index],
              let next = curve.points[safe: index + 1] ?? curve.points[safe: index - 1]
        else { return true }
        return index + 1 < curve.points.count
            ? next.metres >= here.metres
            : here.metres >= next.metres
    }
}

/// The tide as a filled shape across its own width.
private struct TideShape: Shape {
    let points: [TideCurve.Point]
    let span: (low: Double, high: Double)
    var lineOnly = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let range = max(0.001, span.high - span.low)

        for (index, point) in points.enumerated() {
            let x = rect.width * Double(index) / Double(points.count - 1)
            let y = rect.height * (1 - (point.metres - span.low) / range)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        guard !lineOnly else { return path }

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
