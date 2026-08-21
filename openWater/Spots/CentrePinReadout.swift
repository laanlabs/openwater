import OpenWaterCore
import SwiftUI

/// The fixed centre pin and its readout: the Spots map's headline.
///
/// The pin sits dead centre and never moves; the world moves under it, and
/// whatever lands beneath the dot is what the pill above it describes. This
/// is an *overlay* on the map, deliberately not a map annotation — an
/// annotation would enter MapKit's diffing (the pin-strobe class of bug the
/// pins-as-state comment in SpotsTabView exists to prevent) and would need
/// its coordinate chased after every camera move. An overlay is pinned to
/// the glass, which is exactly the interaction: the map slides, the pin
/// stays, the answer changes.
struct CentrePinReadout: View {

    let reading: WindReading?
    /// The fetch finished and this hour has no wind for this point. A dash
    /// is the honest answer; a shimmer would keep promising one.
    var isUnavailable = false
    /// The water under the same dot, when the rider has asked for it in the
    /// layers menu. Its own state rather than an optional, because "not
    /// asked for", "on its way" and "no marine cell here" are three
    /// different answers and only one of them is a missing pill.
    var current: CurrentState = .hidden
    let onTap: () -> Void

    /// What the second pill has to say. Speeds are knots, and `setDeg` is
    /// the set — degrees true, *toward*, which is why it rotates as-is
    /// where the wind arrow above it is flipped. See `CurrentsOutlook`.
    enum CurrentState: Equatable {
        case hidden
        case loading
        /// The model answered for this point and has no water here.
        case unavailable
        case running(speedKn: Double, setDeg: Double)

        var isShowing: Bool { self != .hidden }
    }

    @State private var isPulsing = false

    /// The pill-and-stem stack is drawn hanging *upward* from the map
    /// centre: the dot's middle must sit on the camera's centre coordinate,
    /// so the whole stack rises by half its own height less half the dot —
    /// the same trick as the location picker's `-17`, with a taller pin.
    private var lift: CGFloat {
        (Self.currentBlock(showing: current.isShowing)
            + Self.pillHeight + Self.stemHeight + Self.dotSize) / 2 - Self.dotSize / 2
    }
    private static let pillHeight: CGFloat = 34
    private static let stemHeight: CGFloat = 12
    private static let dotSize: CGFloat = 12
    /// The current pill rides smaller than the wind: the wind is the
    /// headline this map opens for, and a second capsule at the same
    /// weight would make the rider read both before either.
    private static let currentPillHeight: CGFloat = 26
    private static let currentGap: CGFloat = 4

    /// What the current pill adds to the top of the stack, if it is there.
    private static func currentBlock(showing: Bool) -> CGFloat {
        showing ? currentPillHeight + currentGap : 0
    }

    /// How far the readout reaches above the map's centre point: the pill,
    /// its stem, and the half of the dot that sits above the coordinate.
    ///
    /// Published because it is the one number anything else parked in the
    /// middle of the glass needs — the wash's progress hud sat dead centre
    /// and landed across the pill's own number, which is the reading a
    /// rider opened this map for.
    static func heightAboveCentre(showingCurrent: Bool = false) -> CGFloat {
        currentBlock(showing: showingCurrent) + pillHeight + stemHeight + dotSize / 2
    }

    var body: some View {
        VStack(spacing: 0) {
            if current.isShowing {
                currentPill
                    .padding(.bottom, Self.currentGap)
            }
            pill
            Rectangle()
                .fill(Color.mapInk.opacity(0.85))
                .frame(width: 2, height: Self.stemHeight)
                .allowsHitTesting(false)
            Circle()
                .fill(Color.mapInk.opacity(0.85))
                .strokeBorder(.white, lineWidth: 2.5)
                .frame(width: Self.dotSize, height: Self.dotSize)
                .allowsHitTesting(false)
        }
        .offset(y: -lift)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
    }

    /// The readout, in the map pins' shared language at headline size:
    /// arrow pointing downwind (streamline convention — the chrome says
    /// where from), knots, firing tint. Until the fetch lands it breathes
    /// instead of spinning, for the weather chip's reason: a spinner over
    /// a map reads as something being wrong.
    private var pill: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let reading {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 11, weight: .heavy))
                        .rotationEffect(.degrees(reading.directionDeg + 180))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.28), in: Circle())
                    Text("\(Int(reading.speedKn.rounded()))")
                        .font(.system(size: 17, weight: .bold))
                        .monospacedDigit()
                    + Text(" kn")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                } else if isUnavailable {
                    Image(systemName: "wind")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                    Text("—")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    // Waiting. `LoadingPlaceholder` is built for light cards
                    // — its grey fill inside this dark capsule reads as a
                    // solid blank bar, which is precisely how a rider
                    // reported it — so the pill pulses in its own white
                    // instead, unmistakably alive while the hour is fetched.
                    Image(systemName: "wind")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(isPulsing ? 0.55 : 0.2))
                        .frame(width: 38, height: 14)
                        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                                   value: isPulsing)
                        .onAppear { isPulsing = true }
                        .accessibilityLabel("Loading the wind")
                }
            }
            .padding(.vertical, 5)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: Self.pillHeight)
            .foregroundStyle(.white)
            // `mapInk`, not `.primary`: everything on this pill is white,
            // and `.primary` inverts — in dark mode the pill came out white
            // with white numbers on it, which is how a rider photographed
            // it. Map chrome that carries white content has to stay dark in
            // both appearances.
            .background(
                (reading?.isFiring ?? false) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.mapInk.opacity(0.85)),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reading.map { "Wind at the pin: \(Int($0.speedKn.rounded())) knots. Conditions at this point" }
                            ?? "Loading wind at the pin. Conditions at this point")
    }

    /// The water, in the same grammar one line up: an arrow and a number in
    /// a dark capsule. Three things keep the two readable as two rather
    /// than one four-part label — the wave glyph leading it, the smaller
    /// capsule, and the decimal. Half a knot of stream matters the way three
    /// knots of wind do, so this is the one speed on the map printed to a
    /// tenth.
    ///
    /// The arrow rotates by the set with no `+180`. Currents state *toward*
    /// — the one convention in this app where the wind habit would reverse
    /// every river — so both arrows on this stack end up pointing the way
    /// their fluid actually runs, which is what makes them stackable at all.
    private var currentPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "water.waves")
                .font(.system(size: 11, weight: .semibold))
                // Tinted by the currents palette rather than filled with it:
                // slack water is nearly white in that ramp, and a pale
                // capsule under white digits is the dark-mode bug the wind
                // pill's comment above is about. On the glyph it carries the
                // same strength read and costs no legibility.
                .foregroundStyle(currentTint)
            switch current {
            case .running(let speedKn, let setDeg):
                Image(systemName: "location.north.fill")
                    .font(.system(size: 9, weight: .heavy))
                    .rotationEffect(.degrees(setDeg))
                    .foregroundStyle(.white)
                Text(String(format: "%.1f", speedKn))
                    .font(.system(size: 13, weight: .bold))
                    .monospacedDigit()
                + Text(" kt")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            case .unavailable:
                // Inland, or a stretch the ocean model has no cell for. The
                // wind pill's rule: a dash, not a shimmer that never ends.
                Text("—")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            case .loading, .hidden:
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(isPulsing ? 0.55 : 0.2))
                    .frame(width: 28, height: 10)
                    .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                               value: isPulsing)
                    .onAppear { isPulsing = true }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.currentPillHeight)
        .foregroundStyle(.white)
        .background(Color.mapInk.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(.white, lineWidth: 1.5))
        // The wind pill below is the door to the conditions sheet; this one
        // is a reading and nothing more, so a drag that starts on it pans
        // the map rather than being swallowed.
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel(currentLabel)
    }

    private var currentTint: Color {
        guard case .running(let speedKn, _) = current else { return .white.opacity(0.55) }
        return CurrentPalette.color(for: speedKn)
    }

    private var currentLabel: String {
        switch current {
        case .running(let speedKn, let setDeg):
            "Current at the pin: \(String(format: "%.1f", speedKn)) knots, setting \(Format.cardinal(setDeg))"
        case .unavailable: "No current model at the pin"
        case .loading, .hidden: "Loading the current at the pin"
        }
    }
}
