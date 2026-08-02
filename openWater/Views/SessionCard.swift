import CoreLocation
import OpenWaterCore
import SwiftUI

/// A session in the list: the map first, then the numbers.
///
/// The map preview is the point. A rider recognises a session by the shape of
/// the track and where it was long before they read its date — a list of text
/// rows makes every session look like every other one, and finding "the good
/// one from last Tuesday" turns into opening five of them.
struct SessionCard: View {

    let session: StoredSession

    @Environment(AppSettings.self) private var settings

    @State private var showingNotes = false

    private var samples: [PreviewSample] {
        PreviewSample.decode(session.previewTrack)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Always the standard map, whatever the detail maps are set to.
                //
                // A scroll through a season is dozens of these, and satellite
                // previews mean dozens of imagery fetches — on a phone that is
                // often on cellular, at a beach, for a picture 150 points tall
                // where the shoreline reads as brown mush anyway. The shape of
                // the track is the whole job here, and the plain map draws it
                // more clearly and for free.
                TrackThumbnail(
                    id: session.id,
                    samples: samples,
                    style: .standard,
                    height: 150
                )

                // The sport, as a tab riding on the corner of the map — the
                // reference app's shape, and it reads at a glance while
                // scrolling.
                Label(session.sport.displayName, systemImage: session.sport.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.background)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 12))
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(session.startDate.formatted(
                            .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute()
                        ))
                        // Which wrist or pocket it came off. Riders who record
                        // on both end up with two sessions from one afternoon,
                        // and this is the only thing that tells them apart.
                        if let origin = session.origin {
                            Image(systemName: origin.symbol)
                                .font(.caption)
                                .accessibilityLabel(origin.label)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 0) {
                    CardStat(
                        group: "Speed",
                        groupColour: .orange,
                        label: "Max \(settings.units.speed.symbol)",
                        value: Format.speed(session.maxSpeed, unit: settings.units.speed,
                                            decimals: 1, includeSymbol: false)
                    )
                    CardStat(
                        group: " ",
                        groupColour: .orange,
                        // "Avg" next to a total duration invites the reader to
                        // divide distance by time and find it does not agree.
                        // It is the moving average, so it says so.
                        label: "Avg moving",
                        value: Format.speed(session.averageMovingSpeed, unit: settings.units.speed,
                                            decimals: 1, includeSymbol: false)
                    )
                    CardStat(
                        group: "Duration",
                        groupColour: .teal,
                        label: durationLabel,
                        value: Format.duration(session.duration)
                    )
                    CardStat(
                        group: "Distance",
                        groupColour: .blue,
                        label: settings.units.distance.symbol,
                        value: Format.distance(session.distance, unit: settings.units.distance,
                                               includeSymbol: false)
                    )

                    // On the card, not only inside the session.
                    //
                    // "Avg moving" is a choice, and the row above pairs it with
                    // a total duration — so the reader who divides distance by
                    // time and finds it does not agree is looking at *this*
                    // screen when the question occurs. The answer belongs here
                    // rather than two taps away.
                    Button {
                        showingNotes = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 34)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How these numbers were measured")
                    .frame(width: 34, alignment: .trailing)
                }

                if session.sport.isFoiling && session.flightCount > 0 {
                    HStack(spacing: 12) {
                        Badge(systemImage: "airplane",
                              text: "\(Int(session.foilingFraction * 100))% on foil")
                        if session.gybeCount > 0 {
                            Badge(systemImage: "arrow.triangle.turn.up.right.diamond",
                                  text: "\(session.gybeCount) turns")
                        }
                        if session.fallCount > 0 {
                            Badge(systemImage: "figure.fall",
                                  text: "\(session.fallCount) fall\(session.fallCount == 1 ? "" : "s")")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
        .task { await session.backfillPreviewTrack() }
        .sheet(isPresented: $showingNotes) {
            MeasurementNotesView(stored: session)
        }
    }

    private var durationLabel: String {
        session.duration >= 3600 ? "h, m" : "m, s"
    }
}

/// One figure in a card's stat row: a coloured group heading, a quiet unit
/// label, and the number itself with its decimals de-emphasised.
struct CardStat: View {

    let group: String
    let groupColour: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(group)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(groupColour)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            BigNumber(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A number with its leading digits large and everything after the separator
/// small — the reference app's treatment, and it genuinely helps: the digit
/// that matters at a glance is the first one.
struct BigNumber: View {

    let text: String
    var size: CGFloat = 22

    init(_ text: String, size: CGFloat = 22) {
        self.text = text
        self.size = size
    }

    var body: some View {
        let split = Self.split(text)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(split.head)
                .font(.system(size: size, weight: .bold, design: .default))
            if !split.tail.isEmpty {
                Text(split.tail)
                    .font(.system(size: size * 0.62, weight: .semibold))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    /// Break at the first separator, so `12.34` reads as **12**.34 and `1:23:45`
    /// as **1**:23:45.
    static func split(_ text: String) -> (head: String, tail: String) {
        guard let index = text.firstIndex(where: { $0 == "." || $0 == ":" || $0 == "," }) else {
            return (text, "")
        }
        return (String(text[text.startIndex..<index]), String(text[index...]))
    }
}
