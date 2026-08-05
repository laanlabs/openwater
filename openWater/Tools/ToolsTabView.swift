import SwiftUI

/// The Tools tab: single-purpose utilities for the logistics around a
/// session, not the session itself.
///
/// One tool at launch, and a shape that makes the next one cheap: each tool is
/// a row here and a screen of its own. Trends gave up this bar slot — it is a
/// read-occasionally page and lives behind the button at the top of the
/// sessions list — because the tools are the things a rider needs standing on
/// a beach with wet hands.
struct ToolsTabView: View {

    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ShareLocationView()
                    } label: {
                        toolRow(
                            "Share My Location",
                            symbol: "mappin.and.ellipse",
                            blurb: "Send a pin to your shuttle driver — Apple Maps, Google Maps, WhatsApp."
                        )
                    }
                } footer: {
                    Text("Your location is read only while a tool that needs it is open, and leaves this phone only when you tap share.")
                }
            }
            .contentMargins(.bottom, tabBarHeight, for: .scrollContent)
            .navigationTitle("Tools")
        }
    }

    private func toolRow(_ title: String, symbol: String, blurb: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
