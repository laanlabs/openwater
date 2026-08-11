import OpenWaterCore
import SwiftUI

/// Shared pieces for the Tools tab, so every tool shares one idea of how a
/// message leaves the phone.
enum ToolKit {

    /// Which maps app a shared pin should open in.
    ///
    /// A choice rather than sending both: a message carrying two links and a
    /// coordinate pair is a wall of text in a chat thread, and the sender
    /// knows perfectly well which app the person picking them up uses. The
    /// selection sticks, because it is a fact about the rider's friends, not
    /// about this particular pin.
    enum MapProvider: String, CaseIterable, Identifiable {
        case apple, google

        var id: String { rawValue }

        var label: String {
            switch self {
            case .apple: "Apple Maps"
            case .google: "Google Maps"
            }
        }

        func url(for c: Geo.Coordinate, label: String = "Pickup") -> URL {
            let lat = String(format: "%.5f", c.latitude)
            let lon = String(format: "%.5f", c.longitude)
            switch self {
            case .apple:
                let q = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Pin"
                return URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(q)")!
            case .google:
                return URL(string: "https://maps.google.com/?q=\(lat),\(lon)")!
            }
        }
    }

    /// The message body a share uses when it wants to cover both apps — the
    /// shuttle plan and float plan still do, because those go to somebody
    /// making a plan rather than following a pin right now.
    static func mapsLinks(for c: Geo.Coordinate, label: String = "Pickup") -> String {
        let lat = String(format: "%.5f", c.latitude)
        let lon = String(format: "%.5f", c.longitude)
        let encodedLabel = label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Pin"
        return "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(encodedLabel)"
            + " · Google Maps: https://maps.google.com/?q=\(lat),\(lon)"
            + " · \(lat), \(lon)"
    }
}

/// The WhatsApp / Messages / Copy row — direct lines for the two apps session
/// logistics actually happen in, and a copy button for everything else.
struct QuickShareButtons: View {
    let message: String

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            button("WhatsApp", symbol: "bubble.left.and.bubble.right") {
                if let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "https://wa.me/?text=\(encoded)") {
                    openURL(url)
                }
            }
            button("Messages", symbol: "message") {
                if let encoded = message.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: "sms:?&body=\(encoded)") {
                    openURL(url)
                }
            }
            button(copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = message
                withAnimation(.snappy) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.snappy) { copied = false }
                }
            }
        }
    }

    private func button(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

/// An editable message plus the ways to send it — the composer half of every
/// tool that ends in the share sheet. The text is always editable before it
/// goes anywhere: the app drafts, the rider says it their way.
struct MessageComposer: View {
    @Binding var message: String

    var body: some View {
        VStack(spacing: 10) {
            TextEditor(text: $message)
                .font(.subheadline)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 110)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            ShareLink(item: message) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
            }

            QuickShareButtons(message: message)
        }
    }
}

/// The spot page's 12-bar outlook, shared so Wind Here draws the identical
/// strip. Bars at or above 15 kn fill solid — the same "is it on" threshold
/// as everywhere else.
struct WindForecastBars: View {
    let forecast: [WindForecastHour]

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(forecast) { hour in
                    let peak = max(forecast.map(\.speedKn).max() ?? 1, 1)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(hour.speedKn >= 15 ? AnyShapeStyle(.tint)
                              : AnyShapeStyle(Color.foam))
                        .frame(height: max(4, 44 * hour.speedKn / peak))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack {
                Text("now")
                Spacer()
                if let middle = forecast[safe: forecast.count / 2] {
                    Text(middle.date.formatted(.dateTime.hour()))
                }
                Spacer()
                if let last = forecast.last {
                    Text(last.date.formatted(.dateTime.hour()))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// The GPS lifecycle every tool that needs a fix shares: warm-up while the
/// screen is up, off the moment it is not. One modifier so no tool can get
/// the discipline wrong.
struct ToolLocationLifecycle: ViewModifier {
    let recorder: PhoneRecorder
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear {
                recorder.location.requestAuthorization()
                recorder.warmUpSensors()
            }
            .onDisappear { recorder.stopWarmUp() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { recorder.warmUpSensors() }
            }
    }
}

extension View {
    func toolLocation(_ recorder: PhoneRecorder) -> some View {
        modifier(ToolLocationLifecycle(recorder: recorder))
    }
}
