import OpenWaterCore
import SwiftUI

// MARK: - Session Call-out

/// "Start a chat" made practical: the app drafts the message that starts the
/// session — nearest spot, live wind, a time — and the rider's own group
/// thread does the rest. No accounts, no chat infrastructure, no moderation;
/// the crew already has a WhatsApp group and it already works.
struct CallOutView: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(PhoneRecorder.self) private var recorder

    @State private var message = ""
    @State private var time = CallOutView.nextFullHour()
    @State private var composedFor: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                DatePicker("Riding at", selection: $time, displayedComponents: .hourAndMinute)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                MessageComposer(message: $message)

                Text("Drafted from the nearest spot and the current model wind — say it your way before it goes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Session Call-out")
        .navigationBarTitleDisplayMode(.inline)
        .toolLocation(recorder)
        .task(id: draftKey) { await draft() }
        .onChange(of: time) { _, _ in Task { await draft(force: true) } }
    }

    /// Redraft when the fix or the guide arrives — but never over the rider's
    /// own edits: once the text differs from what we last wrote, it is theirs.
    private var draftKey: String {
        "\(recorder.location.lastCoordinate != nil)-\(guide.spots.isEmpty)"
    }

    private static func nextFullHour() -> Date {
        let calendar = Calendar.current
        let next = calendar.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return calendar.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    private func draft(force: Bool = false) async {
        guard force || message.isEmpty || message == composedFor else { return }
        await guide.load()

        var spotName = "the beach"
        var windLine = ""
        if let here = recorder.location.lastCoordinate {
            if let spot = guide.nearestSpot(to: here) { spotName = spot.name }
            if let wind = await guide.currentWind(at: here) {
                windLine = " — \(Int(wind.speedKn.rounded())) kn \(wind.cardinal)"
            }
        }
        let when = time.formatted(date: .omitted, time: .shortened)
        let drafted = "Wind's on at \(spotName)\(windLine). Riding at \(when) — who's in?"
        message = drafted
        composedFor = drafted
    }
}

// MARK: - Float Plan

/// The message you send before you're out of range: where you're launching,
/// where you're landing, when to expect you — and when to actually worry.
/// The cheapest safety gear a downwinder can carry.
struct FloatPlanView: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(PhoneRecorder.self) private var recorder

    @AppStorage("floatPlan.takeout") private var takeout = ""
    @State private var eta = FloatPlanView.defaultETA()
    @State private var message = ""
    @State private var composedFor: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Takeout")
                            .font(.subheadline)
                        TextField("Hood River Event Site", text: $takeout)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    Divider().padding(.leading, 14)
                    DatePicker("Expect me by", selection: $eta, displayedComponents: .hourAndMinute)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                MessageComposer(message: $message)

                Text("The worry time is 45 minutes after your ETA. Includes your launch pin, so the message still helps if plans change and you don't.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Float Plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolLocation(recorder)
        .task(id: "\(recorder.location.lastCoordinate != nil)") { await draft() }
        .onChange(of: eta) { _, _ in Task { await draft(force: true) } }
        .onChange(of: takeout) { _, _ in Task { await draft(force: true) } }
    }

    private static func defaultETA() -> Date {
        Calendar.current.date(byAdding: .minute, value: 90, to: Date()) ?? Date()
    }

    private func draft(force: Bool = false) async {
        guard force || message.isEmpty || message == composedFor else { return }
        await guide.load()

        var launch = "here"
        var pin = ""
        if let here = recorder.location.lastCoordinate {
            if let spot = guide.nearestSpot(to: here) { launch = spot.name }
            pin = " Launch pin: \(ToolKit.mapsLinks(for: here, label: "Launch"))"
        }
        let worry = Calendar.current.date(byAdding: .minute, value: 45, to: eta) ?? eta
        let etaText = eta.formatted(date: .omitted, time: .shortened)
        let worryText = worry.formatted(date: .omitted, time: .shortened)
        let takeoutText = takeout.isEmpty ? "the takeout" : takeout
        let drafted = "Heading out from \(launch), taking out at \(takeoutText). "
            + "Expect me by \(etaText). If you haven't heard from me by \(worryText), call me — then help."
            + pin
        message = drafted
        composedFor = drafted
    }
}

// MARK: - Units Converter

/// Knots to everything, both ways. Trivial, and asked for at every regatta.
struct UnitsConverterView: View {

    @State private var value: Double = 15
    @State private var unit: SpeedUnit = .knots

    private var metresPerSecond: Double { unit.toMetresPerSecond(value) }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Speed", value: $value, format: .number)
                        .keyboardType(.decimalPad)
                        .font(.title2.weight(.semibold))
                    Picker("", selection: $unit) {
                        ForEach(SpeedUnit.allCases, id: \.self) { u in
                            Text(u.symbol).tag(u)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
            Section {
                ForEach(SpeedUnit.allCases.filter { $0 != unit }, id: \.self) { u in
                    LabeledContent(u.symbol) {
                        Text(Format.speed(metresPerSecond, unit: u, decimals: 1, includeSymbol: false))
                            .monospacedDigit()
                    }
                }
                LabeledContent("Beaufort") {
                    Text("F\(beaufort)")
                        .monospacedDigit()
                }
            } footer: {
                Text("Beaufort is approximate — the scale was written for sailors reading the sea, not instruments.")
            }
        }
        .navigationTitle("Units")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Beaufort from the empirical relation v = 0.836·B^1.5 m/s.
    private var beaufort: Int {
        guard metresPerSecond > 0 else { return 0 }
        return min(12, Int(pow(metresPerSecond / 0.836, 2.0 / 3.0).rounded()))
    }
}
