import QuartzCore
import SwiftUI

/// The numbers that explain a hang, on screen when you ask for them.
///
/// A television gives no window into itself — no Xcode attached, no console
/// in the room — so when it drags there is nothing to read. This is a bug
/// button in the corner that opens a small panel of the three figures that
/// actually diagnose a stall on this hardware:
///
/// - **Memory** is the app's physical footprint, the number jetsam watches.
/// - **Available** is how much room is left before the system starts killing
///   the app to reclaim it. This is the one to report when it hangs: a small
///   or falling "available" is memory pressure, and that is a different fix
///   from a slow frame.
/// - **FPS** separates the two: a low frame rate with plenty of memory is the
///   GPU or the main thread working too hard, not a shortage of room.
///
/// The meter only runs while the panel is open — a display link left running
/// would be the app watching itself change what it is watching — so opening it
/// costs nothing the rest of the time.
struct DebugHUD: View {

    @State private var monitor = DebugMonitor()
    @State private var open = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            if open { panel }
            Button { open.toggle() } label: {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(open ? Color.accentColor : .secondary)
                    .frame(width: 60, height: 60)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .onExitCommand(perform: open ? { open = false } : nil)
        }
        .padding(.trailing, 48)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .focusSection()
        .onChange(of: open, initial: true) { _, isOpen in
            if isOpen { monitor.start() } else { monitor.stop() }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Memory", value: String(format: "%.0f MB", monitor.footprintMB), warn: false)
            row("Available",
                value: monitor.availableMB > 0 ? String(format: "%.0f MB", monitor.availableMB) : "—",
                warn: monitor.availableMB > 0 && monitor.availableMB < 120)
            row("FPS", value: String(format: "%.0f", monitor.fps),
                warn: monitor.fps > 0 && monitor.fps < 45)
        }
        .padding(22)
        .frame(width: 300, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func row(_ label: String, value: String, warn: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.white)
        }
    }
}

/// The live figures behind `DebugHUD`, sampled off a display link so the FPS
/// reading is real and the memory reading is current.
@MainActor
@Observable
final class DebugMonitor {

    var fps: Double = 0
    var footprintMB: Double = 0
    var availableMB: Double = 0

    private var link: CADisplayLink?
    private var lastStamp: CFTimeInterval = 0
    private var frames = 0
    private var elapsed: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        sample()
        let created = CADisplayLink(target: self, selector: #selector(tick))
        created.add(to: .main, forMode: .common)
        link = created
    }

    func stop() {
        link?.invalidate()
        link = nil
        lastStamp = 0
        frames = 0
        elapsed = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastStamp == 0 { lastStamp = link.timestamp; return }
        elapsed += link.timestamp - lastStamp
        lastStamp = link.timestamp
        frames += 1
        // Twice a second: often enough to catch a stall, rare enough that the
        // meter is not itself a cost worth measuring.
        guard elapsed >= 0.5 else { return }
        fps = Double(frames) / elapsed
        frames = 0
        elapsed = 0
        sample()
    }

    private func sample() {
        footprintMB = DeviceStats.footprintMB()
        availableMB = DeviceStats.availableMB()
    }
}

/// The two memory numbers, from the kernel.
enum DeviceStats {

    /// The app's physical footprint in megabytes — what the system's
    /// memory-pressure killer measures the app by.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// How much memory the app may still grow into before the system starts
    /// reclaiming it — the early-warning figure for a pressure hang.
    static func availableMB() -> Double {
        Double(os_proc_available_memory()) / 1_048_576
    }
}
