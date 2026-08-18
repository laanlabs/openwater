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
    let onTap: () -> Void

    /// The pill-and-stem stack is drawn hanging *upward* from the map
    /// centre: the dot's middle must sit on the camera's centre coordinate,
    /// so the whole stack rises by half its own height less half the dot —
    /// the same trick as the location picker's `-17`, with a taller pin.
    private var lift: CGFloat { (pillHeight + stemHeight + dotSize) / 2 - dotSize / 2 }
    private let pillHeight: CGFloat = 34
    private let stemHeight: CGFloat = 12
    private let dotSize: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            pill
            Rectangle()
                .fill(Color.primary.opacity(0.85))
                .frame(width: 2, height: stemHeight)
                .allowsHitTesting(false)
            Circle()
                .fill(Color.primary.opacity(0.85))
                .strokeBorder(.white, lineWidth: 2.5)
                .frame(width: dotSize, height: dotSize)
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
                } else {
                    Image(systemName: "wind")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                    LoadingPlaceholder(height: 14, width: 38, corner: 5)
                }
            }
            .padding(.vertical, 5)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: pillHeight)
            .foregroundStyle(.white)
            .background(
                (reading?.isFiring ?? false) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(0.85)),
                in: Capsule()
            )
            .overlay(Capsule().stroke(.white, lineWidth: 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(reading.map { "Wind at the pin: \(Int($0.speedKn.rounded())) knots. Conditions at this point" }
                            ?? "Loading wind at the pin. Conditions at this point")
    }
}
