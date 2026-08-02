import OpenWaterCore
import SwiftUI

/// Fill a session's wind from what was actually blowing at the time.
///
/// Offered, never applied on its own. WeatherKit is a model on a grid a couple
/// of kilometres wide; in a gorge, a bay, or anywhere the geography bends the
/// wind, the local truth can be a long way from it — and the rider was there
/// and it was not. So this fills the same two fields a rider types into, and
/// they can correct it before saving rather than argue with it afterwards.
///
/// It is worth having even so: the alternative is a direction guessed from the
/// shape of the track, and every angle, VMG figure and polar in the session is
/// measured from that guess.
struct RecordedWindRow: View {

    /// The decoded session. Nil while it is still loading, which disables the
    /// button rather than hiding it — a control that appears late is worse than
    /// one that is briefly greyed.
    let session: Session?

    @Binding var directionText: String
    @Binding var speedText: String

    @Environment(AppSettings.self) private var settings

    private enum Lookup: Equatable {
        case idle, loading
        case found(direction: Double, speed: Double)
        case unavailable(String)
    }

    @State private var lookup: Lookup = .idle

    var body: some View {
        switch lookup {
        case .idle:
            Button {
                Task { await fetch() }
            } label: {
                Label("Use recorded conditions", systemImage: "cloud.sun")
            }
            .disabled(session == nil)

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up that afternoon…")
                    .foregroundStyle(.secondary)
            }

        case .found(let direction, let speed):
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    "\(Format.bearing(direction)) at \(Format.speed(speed, unit: settings.units.speed, decimals: 0))",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.green)
                // Attribution is required by WeatherKit's terms wherever its
                // data is shown, and it doubles as the honest caveat: this is
                // a forecast model for the area, not a reading from the beach.
                Text("From  Weather for this spot and time. Edit above if it was not what you felt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .unavailable(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("No recorded conditions", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func fetch() async {
        guard let session else { return }
        // The middle of the session rather than its start: a downwinder can end
        // twenty kilometres from where it began, and the midpoint is the least
        // wrong single place to ask about.
        let points = session.track.points.filter(\.hasValidPosition)
        guard let middle = points[safe: points.count / 2]?.coordinate else {
            lookup = .unavailable("This session has no position to look up.")
            return
        }

        lookup = .loading
        do {
            let wind = try await WeatherLookup.recordedWind(
                at: middle,
                from: session.startDate,
                to: session.endDate
            )
            directionText = String(Int(wind.directionFrom.rounded()))
            if let speed = wind.speed {
                speedText = String(
                    format: "%.0f",
                    settings.units.speed.convert(fromMetresPerSecond: speed)
                )
            }
            lookup = .found(direction: wind.directionFrom, speed: wind.speed ?? 0)
        } catch {
            lookup = .unavailable(Self.explain(error))
        }
    }

    /// Turn WeatherKit's errors into something a rider can act on.
    ///
    /// The common one by far is the app not having the WeatherKit capability on
    /// its App ID, which surfaces as "WDSJWTAuthenticatorServiceListener error
    /// 2" — true, and useless to everybody. It is also not the rider's problem
    /// to solve, so it says so plainly rather than inviting them to try again.
    static func explain(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("WDSJWTAuthenticator") || text.contains("WeatherDaemon") {
            return "Weather is not available in this build of openWater."
        }
        return text
    }
}
