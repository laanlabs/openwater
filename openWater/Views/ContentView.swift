import OpenWaterCore
import SwiftUI

struct ContentView: View {

    @Environment(PhoneRecorder.self) private var recorder

    @State private var selection: ScreenshotRoute.Tab = .sessions

    /// Tabs the rider has actually opened.
    ///
    /// Every visited tab stays in the hierarchy so its scroll position and its
    /// navigation stack survive a trip to another tab — the thing a plain
    /// `switch` on the selection would throw away. Unvisited ones are never
    /// built, so a first launch does not pay for five screens.
    @State private var visited: Set<ScreenshotRoute.Tab> = [.sessions]

    var body: some View {
        // The reader is here to hand the bar the bottom inset it has to fill.
        // Reading it from a view that ignores the bottom safe area is the only
        // way to get the number: the bar's own background has to run all the
        // way down past the home indicator, while its buttons stay above it.
        // Stacked above the bar rather than inset behind it. A safe-area inset
        // is the tidier construction and it only reaches content that reads the
        // safe area — a screen that simply fills its space, like the session
        // map with its panel pinned to the bottom, ran underneath the bar and
        // had its controls cut in half. Nothing can do that to a VStack.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                ZStack {
                    page(.sessions) { SessionListView() }
                    page(.records) { RecordsView() }
                    page(.record) { RecordTabView(isActive: selection == .record) }
                    page(.trends) { TrendsView() }
                    page(.settings) { SettingsView() }
                }
                .frame(maxHeight: .infinity)

                OpenWaterTabBar(
                    selection: $selection,
                    isRecording: recorder.state != .idle,
                    bottomInset: proxy.safeAreaInsets.bottom
                )
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            if let route = ScreenshotRoute.requested { select(route.tab) }
        }
        .onChange(of: selection) { _, new in visited.insert(new) }
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: ScreenshotRoute.Tab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if visited.contains(tab) {
            content()
                .opacity(selection == tab ? 1 : 0)
                .allowsHitTesting(selection == tab)
                // Hidden tabs are still in the tree, and VoiceOver would
                // happily read out a screen nobody can see.
                .accessibilityHidden(selection != tab)
        }
    }

    private func select(_ tab: ScreenshotRoute.Tab) {
        visited.insert(tab)
        selection = tab
    }
}

// MARK: - The bar

/// openWater's tab bar.
///
/// Hand-built rather than `TabView`'s, for one reason: recording is what this
/// app is for, and its button should be bigger than the others and in the
/// middle. A tab bar cannot make one item larger than its neighbours, and
/// floating a circle over the top of the system bar — the obvious hack — leaves
/// it colliding with whatever the screen underneath happens to put near the
/// bottom, which on the Record tab was the Start button.
///
/// So the bar carries a bump instead: the record button sits *in* the
/// silhouette, one shape with the rest of it, raised just enough to read as the
/// primary action and not so far that it becomes something hovering over the
/// content.
struct OpenWaterTabBar: View {

    @Binding var selection: ScreenshotRoute.Tab
    var isRecording: Bool
    /// Height of the home-indicator strip, which the bar's background covers.
    var bottomInset: CGFloat = 0

    /// How far the middle of the bar rises. Deliberately small — the point is
    /// emphasis, not a floating action button.
    private let rise: CGFloat = 12
    private let barHeight: CGFloat = 50
    private let buttonSize: CGFloat = 44

    var body: some View {
        // Every cell owns the full height of the bar including the rise, so the
        // part of the record button that sticks up into the bump is inside its
        // own hit area. Laid out any other way it draws above its button's
        // bounds and the most prominent control in the app quietly stops
        // responding to taps on its top half.
        HStack(spacing: 0) {
            item(.sessions, "Sessions", "list.bullet")
            item(.records, "Bests", "trophy")
            recordItem
            item(.trends, "Trends", "chart.xyaxis.line")
            item(.settings, "Settings", "gearshape")
        }
        .frame(height: rise + barHeight)
        .padding(.bottom, bottomInset)
        .background {
            let shape = BumpedBarShape(rise: rise, bumpRadius: buttonSize / 2 + 6)
            // Attached to the bottom edge and running the full width, with the
            // background covering the home-indicator strip. A floating capsule
            // wastes a band of screen on every side of itself, and this app
            // spends its screen on maps.
            //
            // Opaque rather than a material: a translucent bar looks lovely over
            // a list and turns to mush over the Record tab's map, and there are
            // ten-point labels on it.
            shape
                .fill(.background)
                .overlay { shape.stroke(Color(.separator).opacity(0.55), lineWidth: 0.5) }
        }
    }

    // MARK: Items

    private func item(_ tab: ScreenshotRoute.Tab, _ title: String, _ symbol: String) -> some View {
        let selected = selection == tab
        return Button {
            select(tab)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .symbolVariant(selected ? .fill : .none)
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.top, rise)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var recordItem: some View {
        let selected = selection == .record
        return Button {
            select(.record)
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Circle()
                        .fill(isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    Image(systemName: "record.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: buttonSize, height: buttonSize)
                // A ring in the recording colour, so a glance at the bar from
                // any tab says whether a session is still running.
                .overlay {
                    if isRecording {
                        Circle()
                            .stroke(.red.opacity(0.35), lineWidth: 3)
                            .padding(-4)
                    }
                }

                Text(isRecording ? "Recording" : "Record")
                    .font(.system(size: 10, weight: selected || isRecording ? .semibold : .regular))
                    .foregroundStyle(isRecording ? AnyShapeStyle(.red)
                                     : selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            // Top-aligned so the circle sits in the bump, with the label under
            // it on roughly the same line as the other four.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Record")
        .accessibilityValue(isRecording ? "Recording" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ tab: ScreenshotRoute.Tab) {
        guard selection != tab else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.snappy(duration: 0.18)) { selection = tab }
    }
}

/// A bar with a raised round bump in the middle.
///
/// Drawn as one filled path — a rounded rectangle and a circle overlapping —
/// so the bump belongs to the bar's silhouette rather than being a second shape
/// sitting on top of it. That is the whole difference between "integrated" and
/// "stuck on".
struct BumpedBarShape: Shape {

    var rise: CGFloat
    var bumpRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Square: the bar meets the screen edges, so there is nothing for a
        // corner radius to round against.
        let bar = CGRect(
            x: rect.minX,
            y: rect.minY + rise,
            width: rect.width,
            height: rect.height - rise
        )
        path.addRect(bar)

        // Centred on the bar's top edge and pulled up by the rise, so the two
        // shapes overlap by well over half the circle and the join reads as a
        // swell rather than a bubble balanced on a line.
        path.addEllipse(in: CGRect(
            x: rect.midX - bumpRadius,
            y: bar.minY - rise,
            width: bumpRadius * 2,
            height: bumpRadius * 2
        ))

        return path
    }
}
