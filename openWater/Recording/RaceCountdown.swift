import AudioToolbox
import Foundation
import SwiftUI
import UIKit
import os

/// A regatta start sequence: five minutes down to zero, with the cues.
///
/// The rules that matter here come from how a start actually works. The
/// committee's gun is the truth, and a rider starting their own timer on the
/// signal is always a second or two late — so the timer can be **synced**:
/// tapping sync jumps to the nearest whole minute, which is what every sailing
/// watch does and what people expect. Late by twenty seconds, sync takes you
/// back to the minute; early by twenty, it takes you forward to it.
///
/// The cues are audible and haptic, because at the start you are looking at the
/// line, the other boats and the committee boat — never at your phone.
///
/// This is a paid feature in the app openWater is modelled on. It is free here,
/// like everything else.
@MainActor
@Observable
final class RaceCountdown {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "Countdown")

    /// When the gun goes. `nil` when no sequence is running.
    private(set) var target: Date?

    /// Seconds until the start. Negative once it has gone, so a rider who is
    /// late can see by how much.
    private(set) var remaining: TimeInterval = 0

    /// Called when the countdown reaches zero. The Record tab uses it to start
    /// recording without a tap.
    var onStart: (() -> Void)?

    var isRunning: Bool { target != nil }

    /// The length last used, so the next race starts from the same place.
    var lastDuration: Int {
        get { UserDefaults.standard.object(forKey: "countdownMinutes") as? Int ?? 5 }
        set { UserDefaults.standard.set(newValue, forKey: "countdownMinutes") }
    }

    private var ticker: Task<Void, Never>?
    private var lastCueSecond: Int?
    private var hasFired = false

    // MARK: - Control

    func start(minutes: Int) {
        lastDuration = minutes
        begin(at: Date().addingTimeInterval(Double(minutes) * 60))
    }

    /// Snap to the nearest whole minute — the sync every sailing watch has.
    ///
    /// Rounding to *nearest* rather than down is the whole point: a rider who
    /// hits the button two seconds late wants the minute they missed, not to
    /// lose fifty-eight seconds of sequence.
    func sync() {
        guard let target else { return }
        let seconds = target.timeIntervalSinceNow
        guard seconds > 0 else { return }
        let minutes = max(1, (seconds / 60).rounded())
        begin(at: Date().addingTimeInterval(minutes * 60))
        cue(.sync)
    }

    /// Drop a whole minute — for a postponed or general-recalled start.
    func addMinute() {
        guard let target else { return }
        begin(at: target.addingTimeInterval(60))
    }

    func cancel() {
        ticker?.cancel()
        ticker = nil
        target = nil
        remaining = 0
        lastCueSecond = nil
        hasFired = false
    }

    private func begin(at date: Date) {
        target = date
        hasFired = false
        lastCueSecond = nil
        remaining = date.timeIntervalSinceNow

        ticker?.cancel()
        ticker = Task { [weak self] in
            // Driven off wall-clock time rather than counting ticks, so a
            // dropped frame or a moment in the background cannot make the
            // sequence drift away from the committee's clock.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let target = self.target else { return }
                self.remaining = target.timeIntervalSinceNow
                self.cueIfNeeded()
            }
        }
    }

    // MARK: - Cues

    private func cueIfNeeded() {
        let second = Int(ceil(remaining))
        guard second != lastCueSecond else { return }
        lastCueSecond = second

        if remaining <= 0, !hasFired {
            hasFired = true
            cue(.gun)
            Self.logger.info("countdown reached zero")
            onStart?()
            // The sequence is over. Left running, the ticker kept writing
            // `remaining` ten times a second for the rest of the app's life —
            // through the whole recording it had just started — and the sheet,
            // reopened, showed a start that had long gone instead of the
            // picker for the next one.
            ticker?.cancel()
            ticker = nil
            target = nil
            return
        }

        switch second {
        // The minute marks, then the last ten seconds one at a time —
        // the standard sequence, and the one people's ears already know.
        case 300, 240, 180, 120, 60, 30, 20:
            cue(.minute)
        case 1...10:
            cue(.second)
        default:
            break
        }
    }

    private enum Cue { case second, minute, gun, sync }

    private func cue(_ cue: Cue) {
        switch cue {
        case .second:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            AudioServicesPlaySystemSound(1103)
        case .minute:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            AudioServicesPlaySystemSound(1113)
        case .gun:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            AudioServicesPlaySystemSound(1005)
        case .sync:
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    // MARK: - Display

    /// `4:32`, or `+0:07` once the gun has gone.
    var display: String {
        let seconds = Int(abs(remaining).rounded(.down))
        let text = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return remaining < 0 ? "+\(text)" : text
    }

    /// Red inside the last minute, amber in the last two — readable at arm's
    /// length in the water, which is the only place this is ever used.
    var tint: Color {
        if remaining <= 0 { return .green }
        if remaining <= 60 { return .red }
        if remaining <= 120 { return .orange }
        return .primary
    }
}
