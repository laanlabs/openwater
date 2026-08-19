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

    /// Bumped whenever Record is tapped, including when it is already showing.
    ///
    /// Record means "I want to record", not "show me that tab as I left it".
    /// Saving a session pushes its detail onto the Record tab, so a rider who
    /// finishes a session and then wants another one is looking at the summary
    /// of the last — and tapping Record, the obvious thing, did nothing at all
    /// because the tab was already selected.
    @State private var recordTabReset = 0
    @State private var sessionsTabReset = 0
    @State private var toolsTabReset = 0
    @State private var spotsTabReset = 0

    /// Room kept clear for the bar. The capsule is 62 points tall including its
    /// rise, and it sits 6 above the home indicator.
    private let barReservedHeight: CGFloat = 68

    var body: some View {
        // The reader is here to hand the bar the bottom inset it has to fill.
        // Reading it from a view that ignores the bottom safe area is the only
        // way to get the number: the bar's own background has to run all the
        // way down past the home indicator, while its buttons stay above it.
        // The bar floats over the content rather than sitting in a slot below
        // it: `safeAreaPadding` reserves the room so nothing important ends up
        // underneath, while the pages still draw the full height behind it —
        // which is what makes a floating bar look like one instead of a strip
        // stuck to a wall.
        ZStack(alignment: .bottom) {
            ZStack {
                page(.sessions) { SessionListView(reset: sessionsTabReset) }
                page(.spots) { SpotsTabView(reset: spotsTabReset) }
                page(.record) {
                    RecordTabView(isActive: selection == .record, reset: recordTabReset)
                }
                page(.tools) { ToolsTabView(reset: toolsTabReset) }
                page(.settings) { SettingsView() }
            }
            // No inset here. Neither `padding` nor `safeAreaPadding` at this
            // level does the right thing for every page: plain padding shortens
            // them all so nothing is ever drawn under the bar — which leaves a
            // band of background below it and makes the glass pointless, since
            // there is nothing behind it to see — and the safe-area version
            // does not reach a page rooted in a `NavigationStack` at all, which
            // put the Record tab's Start button and the session map's transport
            // row underneath it.
            //
            // So each page takes the room in the way that suits it, from
            // `floatingTabBarHeight` below: the scrolling ones as a content
            // margin, so they draw through the glass and can still be scrolled
            // clear, and the two that end in a fixed control as plain padding.

            OpenWaterTabBar(
                selection: $selection,
                isRecording: recorder.state != .idle,
                onSelect: { tab in
                    visited.insert(tab)
                    if tab == .record { recordTabReset += 1 }
                    if tab == .sessions { sessionsTabReset += 1 }
                    if tab == .tools { toolsTabReset += 1 }
                    // Deliberately not bumped by the route handoff below:
                    // that arrives with something for the map to open, and
                    // this is the tap that closes things.
                    if tab == .spots { spotsTabReset += 1 }
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWaterSwitchToRecord)) { _ in
            visited.insert(.record)
            recordTabReset += 1
            withAnimation(.snappy(duration: 0.18)) { selection = .record }
        }
        // A tool asked the Spots map to open a route. The payload rides
        // `RouteHandoff`, not the notification — this page's only job is
        // getting the tab on screen; a freshly built Spots page consumes
        // the seam from its own `onAppear`.
        .onReceive(NotificationCenter.default.publisher(for: .openWaterOpenRoute)) { _ in
            visited.insert(.spots)
            withAnimation(.snappy(duration: 0.18)) { selection = .spots }
        }
        // Published for the screens that cannot use the safe-area inset.
        //
        // A scrolling page just draws through the bar and stops its content
        // short, which is what `safeAreaPadding` above arranges. A page that
        // fills its space and puts a fixed control at the bottom — the session
        // map's transport row is the one — gets no such help from it, and the
        // control ends up under the glass with no way to scroll it out. Those
        // screens read this and keep clear themselves.
        .environment(\.floatingTabBarHeight, barReservedHeight - 6)
        // The bar stays at the bottom of the screen when a keyboard opens
        // instead of riding up on top of it. It had been sitting exactly where
        // the keyboard's own accessory bar goes, drawing over the "Done" button
        // that dismisses a number pad — which is why a decimal pad, having no
        // return key, could not be closed at all. A system tab bar hides behind
        // the keyboard for this reason; the pages inside still get the keyboard
        // inset, because each one scrolls itself.
        .ignoresSafeArea(.keyboard, edges: .bottom)
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

    /// Reported for every tap, including one on the tab already showing —
    /// which is the case the Record tab needs in order to reset itself.
    var onSelect: (ScreenshotRoute.Tab) -> Void = { _ in }

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
            item(.spots, "Spots", "mappin.and.ellipse")
            recordItem
            item(.tools, "Tools", "wrench.and.screwdriver")
            item(.settings, "Settings", "gearshape")
        }
        .frame(height: rise + barHeight)
        .background {
            let shape = BumpedBarShape(rise: rise, bumpRadius: buttonSize / 2 + 6, cornerRadius: barHeight / 2)
            // Glass, so the track or the list scrolling underneath is visible
            // through it and the bar reads as floating above the page rather
            // than as a strip walling off the bottom of it.
            //
            // `.regularMaterial` rather than `.ultraThin`: the labels on here
            // are ten points, and over the Record tab's satellite map a thinner
            // material leaves them fighting the imagery. The hairline is what
            // keeps the edge legible where the content behind happens to match
            // the material, and the shadow is what sells the float.
            shape
                .fill(.regularMaterial)
                .overlay { shape.stroke(Color(.separator).opacity(0.6), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        }
        // A floating capsule only floats if it is smaller than the water it
        // sits on. Stretched across an iPad it reads as a wall again — five
        // buttons adrift in it, thumbs' width apart — so the bar keeps a
        // phone's proportions and centres itself, whatever the window does.
        .frame(maxWidth: 520)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
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
        onSelect(tab)
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
    /// Rounding on the bar itself. Half its height gives the capsule.
    var cornerRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let bar = CGRect(
            x: rect.minX,
            y: rect.minY + rise,
            width: rect.width,
            height: rect.height - rise
        )
        path.addRoundedRect(in: bar, cornerSize: CGSize(width: cornerRadius, height: cornerRadius))

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


// MARK: - Bar height

private struct FloatingTabBarHeightKey: EnvironmentKey {
    /// Zero, so a screen presented outside the tab container — a sheet, a
    /// full-screen cover — reads the honest answer rather than reserving room
    /// for a bar that is not there.
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Room the floating tab bar occupies at the bottom of the window.
    var floatingTabBarHeight: CGFloat {
        get { self[FloatingTabBarHeightKey.self] }
        set { self[FloatingTabBarHeightKey.self] = newValue }
    }
}
