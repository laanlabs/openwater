import Foundation
import WatchKit
import os

/// Water Lock, asked for the way watchOS will actually grant it.
///
/// Apple's rule, from the `enableWaterLock()` documentation: it can only be
/// enabled while the app is in the foreground *during an active workout or
/// location session*. Outside that it is silently ignored — no error, no
/// return value — and this app called it in two places where that was true:
/// once at launch, before any session existed, and once the instant after
/// `startActivity`, before the workout had become active. Neither ever took
/// on a real wrist, including the day a session was lost to a wet sleeve,
/// and the code had no way of knowing.
///
/// `isWaterLockEnabled` does say afterwards whether it took. So this asks on
/// a schedule and stops at the first success, and returns whether there was
/// one — so a caller can say "locked" only when it is.
enum WaterLock {

    private static let logger = Logger(subsystem: "com.laan.labs.openWater", category: "WaterLock")

    /// Try at each delay in turn, checking after each; true on the first
    /// attempt that took.
    @MainActor
    @discardableResult
    static func engage(after delays: [Double]) async -> Bool {
        let device = WKInterfaceDevice.current()
        for delay in delays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            device.enableWaterLock()
            try? await Task.sleep(for: .milliseconds(250))
            if device.isWaterLockEnabled {
                logger.notice("water lock engaged after \(delay, format: .fixed(precision: 1))s")
                return true
            }
        }
        logger.notice("water lock did not engage after \(delays.count) attempts")
        return false
    }
}
