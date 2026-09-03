import OpenWaterSpots
import SwiftUI

// MARK: - The picker

/// The model sheet: automatic on top and set apart, because it is the
/// recommendation rather than one of the options, then the models by name
/// with what each is actually good for. Picking one changes every model
/// wind number in the app — pins, wash, flow map, routes, and the
/// conditions detail — so the note at the bottom says so plainly.
struct ForecastModelSheet: View {

    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    private var chosen: ForecastModel {
        ForecastModel(rawValue: selection) ?? .automatic
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.automatic)
                }
                Section {
                    ForEach(ForecastModel.allCases.filter { $0 != .automatic }) { model in
                        row(model)
                    }
                } header: {
                    Text("Or name one")
                } footer: {
                    Text("The models disagree, and near a coast they disagree by more than a knot or two — which is the point of choosing. Your pick answers for every wind number in the app: the pins, the wash, the flow map and route forecasts. Observations are never modelled and never change.")
                }
            }
            .navigationTitle("Wind model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ model: ForecastModel) -> some View {
        Button {
            selection = model.rawValue
            ForecastModel.selected = model
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if chosen == model {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
