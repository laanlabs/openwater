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
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section("Logistics") {
                    NavigationLink {
                        ShareLocationView()
                    } label: {
                        toolRow("Share My Location", symbol: "mappin.and.ellipse",
                                blurb: "Send a pin to your shuttle driver — Apple Maps, Google Maps, WhatsApp.")
                    }
                    NavigationLink {
                        CallOutView()
                    } label: {
                        toolRow("Session Call-out", symbol: "megaphone",
                                blurb: "Spot, wind and a time in one message. Who's in?")
                    }
                    NavigationLink {
                        FloatPlanView()
                    } label: {
                        toolRow("Float Plan", symbol: "checkmark.shield",
                                blurb: "Where you're going and when to worry, sent before you're out of range.")
                    }
                    NavigationLink {
                        ShuttlePlannerView()
                    } label: {
                        toolRow("Shuttle Planner", symbol: "car.2",
                                blurb: "Run distance, and whether today's wind actually points down it.")
                    }
                }

                Section("Conditions") {
                    NavigationLink {
                        WindHereView()
                    } label: {
                        toolRow("Wind Here", symbol: "wind",
                                blurb: "Model wind and the next 12 hours, at your feet.")
                    }
                    NavigationLink {
                        DaylightView()
                    } label: {
                        toolRow("Daylight", symbol: "sunset",
                                blurb: "Sunset, last usable light, and how long you've got.")
                    }
                }

                Section("Instruments") {
                    NavigationLink {
                        BigSpeedoView()
                    } label: {
                        toolRow("Speedo", symbol: "gauge.with.needle",
                                blurb: "Just the speed, huge. No recording.")
                    }
                }

                Section("Spot Guide") {
                    NavigationLink {
                        ImproveSpotHubView()
                    } label: {
                        toolRow("Add or Fix a Spot", symbol: "camera.badge.ellipsis",
                                blurb: "Standing at a launch? Photograph it and send it to the guide.")
                    }
                }

                Section("Find Used Gear") {
                    // A Button, not a `Link`: Link tints its entire label and
                    // wins against explicit foreground styles on the children,
                    // which turned this whole row orange. The arrow and icon
                    // carry the "external" signal; the text stays readable.
                    Button {
                        openURL(URL(string: "https://usedwatersports.com/")!)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "cart")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 34, height: 34)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Used Watersports")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Second-hand wings, foils and boards — usedwatersports.com")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    NavigationLink {
                        UnitsConverterView()
                    } label: {
                        toolRow("Units", symbol: "arrow.left.arrow.right",
                                blurb: "Knots to everything, both ways.")
                    }
                } header: {
                    Text("Reference")
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
