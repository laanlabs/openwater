import OpenWaterCore
import SwiftUI

/// Sport selection as a grid of cards.
///
/// This was a picker row, which was wrong for the one decision that matters
/// most in the whole app. The sport is not a label — it selects every detection
/// threshold there is, so choosing it wrongly does not produce slightly wrong
/// flights and gybes, it produces meaningless ones. A control that has to be
/// tapped, then scrolled, then tapped again buries that.
///
/// The wind-powered and foiling sports come first because that is what this app
/// is for; everything else follows.
struct SportPicker: View {

    @Binding var selection: Sport

    /// Compact mode fits the pre-session screen; full mode is for editing.
    var showsAllSports: Bool = true

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    /// Ordered by how likely a rider of this app is to pick it.
    private static let primary: [Sport] = [.wingfoil, .parawing, .downwindSUP, .prone, .supFoil]
    private static let secondary: [Sport] = [.windfoil, .windsurf, .kitefoil, .kitesurf]
    private static let rest: [Sport] = [.sail, .sup, .kayak, .efoil, .tow, .other]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            group(Self.primary, title: nil)
            group(Self.secondary, title: "Other wind sports")
            if showsAllSports {
                group(Self.rest, title: "More")
            }
        }
    }

    @ViewBuilder
    private func group(_ sports: [Sport], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(sports) { sport in
                    SportCard(sport: sport, isSelected: sport == selection) {
                        selection = sport
                    }
                }
            }
        }
    }
}

struct SportCard: View {
    let sport: Sport
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: sport.symbolName)
                    .font(.title2)
                Text(sport.displayName)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 78)
            .padding(.horizontal, 4)
            .background(
                isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.6)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A compact row that opens the full picker — for places where the grid is too
/// much, like a form.
struct SportRow: View {
    @Binding var selection: Sport

    var body: some View {
        NavigationLink {
            SportPickerPage(selection: $selection)
        } label: {
            HStack {
                Label(selection.displayName, systemImage: selection.symbolName)
            }
        }
    }
}

/// The pushed picker, with a draft and a Done button.
///
/// This has been both other things. Behind a plain Back button the page
/// read as if a tap did nothing — "there's no save, only a back button".
/// Popping on the first tap fixed that and was abrupt in its own way: a
/// rider comparing two sports wants to tap around, and the page vanished
/// under the first tap. So the tap picks a *draft*, the page says what
/// choosing it will do, and Done commits it to the form underneath — whose
/// Save button says "Save & Recalculate" from that moment. Back discards
/// the draft; nothing is saved from here.
private struct SportPickerPage: View {
    @Binding var selection: Sport
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var draft: Sport

    init(selection: Binding<Sport>) {
        _selection = selection
        _draft = State(initialValue: selection.wrappedValue)
    }

    private var changed: Bool { draft != selection }

    var body: some View {
        Form {
            Section {
                SportPicker(selection: $draft)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            } footer: {
                if changed {
                    Label(
                        "Choosing \(draft.displayName) will recalculate this session when you save: "
                        + "flights, turns, falls and every speed category are detected with "
                        + "\(draft.displayName)'s thresholds"
                        + (draft.isFoiling
                           ? ", flying above \(Format.speed(draft.thresholds.foilTakeoffSpeed, unit: settings.units.speed, decimals: 1))"
                           : "")
                        + ". Tap Done to choose it, or Back to keep \(selection.displayName).",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Text("The sport sets the thresholds openWater uses to detect flights, gybes and falls. Tap one to see what changes; Done chooses it.")
                }
            }
        }
        .navigationTitle("Sport")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Sport picker")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(changed ? "Done" : "Keep") {
                    selection = draft
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
