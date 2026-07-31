import OpenWaterCore
import SwiftUI
import WatchKit

/// A racing start sequence on the wrist.
///
/// Sailing starts run to a fixed sequence of gun signals, and the whole skill is
/// arriving at the line at full speed exactly on zero — not before, not after.
/// A stopwatch is not good enough because the sequence gets synced to the
/// committee boat's guns, so the essential feature is **sync**: tapping at a gun
/// snaps the clock to the nearest whole minute rather than resetting it.
///
/// Haptics matter more than the display here. Nobody is looking at their wrist
/// in the last ten seconds of a start.
struct CountdownPage: View {

    @State private var model = CountdownModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text(model.display)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(model.colour)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)

                if model.isRunning {
                    HStack(spacing: 6) {
                        Button("Sync") { model.syncToNearestMinute() }
                            .tint(.blue)
                        Button("Stop") { model.stop() }
                            .tint(.red)
                    }
                    .font(.caption2)
                    Text("Sync snaps to the nearest whole minute — tap it on the gun.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                } else {
                    HStack(spacing: 6) {
                        ForEach([5, 3, 1], id: \.self) { minutes in
                            Button("\(minutes)m") { model.start(minutes: minutes) }
                                .tint(.green)
                        }
                    }
                    .font(.caption2)
                }
            }
            .padding(.horizontal, 2)
        }
        .containerBackground(.indigo.gradient.opacity(0.18), for: .tabView)
        .onDisappear { model.stopTickingIfIdle() }
    }
}

@MainActor
@Observable
final class CountdownModel {

    private(set) var remaining: TimeInterval = 0
    private(set) var isRunning = false

    private var target: Date?
    private var timer: Timer?
    /// Whole seconds already announced, so each one fires its haptic once.
    private var lastAnnouncedSecond: Int?

    var display: String {
        guard isRunning else { return "--:--" }
        if remaining <= 0 {
            return "GO"
        }
        let total = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var colour: Color {
        guard isRunning else { return .secondary }
        if remaining <= 0 { return .green }
        if remaining <= 10 { return .red }
        if remaining <= 60 { return .orange }
        return .primary
    }

    func start(minutes: Int) {
        target = Date().addingTimeInterval(TimeInterval(minutes * 60))
        isRunning = true
        lastAnnouncedSecond = nil
        startTicking()
        WKInterfaceDevice.current().play(.start)
    }

    /// Snap to the nearest whole minute.
    ///
    /// If the gun goes at 4:52 remaining, the sequence is really at 5:00 and the
    /// watch is eight seconds slow — so it jumps forward. At 5:07 it jumps back.
    /// Rounding to the nearest rather than always up or down is what makes one
    /// tap correct in both directions.
    func syncToNearestMinute() {
        guard isRunning, let target else { return }
        let remaining = target.timeIntervalSinceNow
        guard remaining > 0 else { return }
        let minutes = (remaining / 60).rounded()
        self.target = Date().addingTimeInterval(minutes * 60)
        lastAnnouncedSecond = nil
        WKInterfaceDevice.current().play(.click)
    }

    func stop() {
        isRunning = false
        target = nil
        remaining = 0
        timer?.invalidate()
        timer = nil
    }

    func stopTickingIfIdle() {
        guard !isRunning else { return }
        timer?.invalidate()
        timer = nil
    }

    private func startTicking() {
        timer?.invalidate()
        // 0.1 s so the second boundaries — and therefore the haptics — land on
        // time rather than up to a second late.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let target else { return }
        remaining = target.timeIntervalSinceNow

        let second = Int(remaining.rounded(.up))
        if second != lastAnnouncedSecond {
            lastAnnouncedSecond = second
            announce(second)
        }

        if remaining <= -5 {
            // Past the start; stop ticking rather than running forever.
            stop()
        }
    }

    /// The haptic pattern mirrors what a sailor expects to hear: a tick each
    /// minute, a tick each of the last ten seconds, and a distinct signal on
    /// the gun.
    private func announce(_ second: Int) {
        let device = WKInterfaceDevice.current()
        switch second {
        case 0:
            device.play(.success)
        case 1...10:
            device.play(.click)
        case let s where s > 0 && s % 60 == 0:
            device.play(.notification)
        default:
            break
        }
    }
}
