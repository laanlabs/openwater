import OpenWaterCore
import SwiftUI

/// Everything the rider owns, so a session records which of it was used
/// rather than what they could remember typing.
///
/// Foil gear is mixed and matched — one mast under three front wings, a tail
/// swapped between sessions — so the quiver is a flat list of parts rather
/// than a set of complete setups. Assembling them is what a session is for.
///
/// Free text under the categories, deliberately: a fixed catalogue is out of
/// date the week it ships and never contains the prototype somebody is
/// actually riding.
struct GearItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: GearKind
    var brand: String = ""
    var model: String = ""

    /// What a session shows. Brand and model together when both are known,
    /// because "1099" means nothing next to somebody else's "1099".
    var display: String {
        [brand, model]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isEmpty: Bool { display.isEmpty }
}

enum GearKind: String, Codable, CaseIterable, Identifiable {
    case board, frontWing, fuselage, tail, mast, wing, parawing, paddle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: "Boards"
        case .frontWing: "Front wings"
        case .fuselage: "Fuselages"
        case .tail: "Tails"
        case .mast: "Masts"
        case .wing: "Wings"
        case .parawing: "Parawings"
        case .paddle: "Paddles"
        }
    }

    var one: String {
        switch self {
        case .board: "Board"
        case .frontWing: "Front wing"
        case .fuselage: "Fuselage"
        case .tail: "Tail"
        case .mast: "Mast"
        case .wing: "Wing"
        case .parawing: "Parawing"
        case .paddle: "Paddle"
        }
    }

    var icon: String {
        switch self {
        case .board: "surfboard"
        case .frontWing, .tail: "airplane"
        case .fuselage: "minus"
        case .mast: "arrow.up.and.down"
        case .wing: "wind"
        case .parawing: "paperplane"
        case .paddle: "figure.rowing"
        }
    }

    /// The two halves of a setup, kept apart because they are chosen
    /// separately: a rider swaps front wings between runs and keeps the same
    /// wing all season, or the reverse.
    static let foil: [GearKind] = [.frontWing, .fuselage, .tail, .mast, .board]
    static let driver: [GearKind] = [.wing, .parawing, .paddle]

    /// Where this kind lands on a session's equipment record.
    var path: WritableKeyPath<Equipment, String> {
        switch self {
        case .board: \.board
        case .frontWing: \.frontWing
        case .fuselage: \.fuselage
        case .tail: \.tail
        case .mast: \.mast
        case .wing: \.wing
        case .parawing: \.parawing
        case .paddle: \.paddle
        }
    }
}

/// The quiver, managed.
struct QuiverView: View {

    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Text("What you own, so a session can be tagged with it in two taps "
                     + "instead of being typed out. Add as much or as little as you like — "
                     + "a front wing you ride every day is worth more here than a complete inventory.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(GearKind.allCases) { kind in
                Section {
                    ForEach($settings.quiver.filter { $0.wrappedValue.kind == kind }) { $item in
                        HStack {
                            TextField("Brand", text: $item.brand)
                                .frame(maxWidth: 120)
                            Divider()
                            TextField("Model or size", text: $item.model)
                        }
                    }
                    .onDelete { offsets in remove(kind: kind, at: offsets) }

                    Button {
                        settings.quiver.append(GearItem(kind: kind))
                    } label: {
                        Label("Add \(kind.one.lowercased())", systemImage: "plus")
                            .font(.callout)
                    }
                } header: {
                    Label(kind.title, systemImage: kind.icon)
                }
            }
        }
        .navigationTitle("Quiver")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onDisappear {
            // Empty rows are how somebody leaves a mind changed; nothing is
            // gained by keeping them.
            settings.quiver.removeAll(where: \.isEmpty)
        }
    }

    private func remove(kind: GearKind, at offsets: IndexSet) {
        let matching = settings.quiver.enumerated().filter { $0.element.kind == kind }
        let doomed = offsets.map { matching[$0].offset }
        settings.quiver.remove(atOffsets: IndexSet(doomed))
    }
}
