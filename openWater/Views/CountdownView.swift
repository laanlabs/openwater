import SwiftUI

/// The start sequence, big enough to read from the water.
///
/// Everything on this screen is sized for a rider holding a phone at arm's
/// length with salt on the lens: one enormous number, three fat buttons, no
/// chrome. The controls are the ones a start actually needs — sync to the
/// committee's signal, add a minute for a postponement, and abandon.
struct CountdownView: View {

    @Environment(RaceCountdown.self) private var countdown
    @Environment(\.dismiss) private var dismiss

    /// Started automatically when the gun goes.
    var onStart: () -> Void

    private let options = [1, 3, 5, 10]

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                if countdown.isRunning {
                    running
                } else {
                    setup
                }

                Spacer()
            }
            .padding(24)
            .navigationTitle("Race Start")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            countdown.onStart = {
                onStart()
                dismiss()
            }
        }
    }

    // MARK: - Before

    private var setup: some View {
        VStack(spacing: 22) {
            Image(systemName: "flag.checkered.2.crossed")
                .font(.system(size: 54))
                .foregroundStyle(.tint)

            Text("Start the sequence when the committee signals. Recording begins on its own at zero.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ForEach(options, id: \.self) { minutes in
                Button {
                    countdown.start(minutes: minutes)
                } label: {
                    Text("\(minutes) minute\(minutes == 1 ? "" : "s")")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .tint(minutes == countdown.lastDuration ? .accentColor : .secondary.opacity(0.25))
                .foregroundStyle(minutes == countdown.lastDuration ? .white : .primary)
            }
        }
    }

    // MARK: - Running

    private var running: some View {
        VStack(spacing: 26) {
            Text(countdown.display)
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(countdown.tint)
                .contentTransition(.numericText())
                .animation(.snappy, value: countdown.display)

            Text(countdown.remaining > 0 ? "to the gun" : "since the gun")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    countdown.sync()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.trianglehead.counterclockwise")
                        Text("Sync")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Button {
                    countdown.addMinute()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "plus")
                        Text("+1 min")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    countdown.cancel()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "xmark")
                        Text("Abandon")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
            }

            Text("Sync jumps to the nearest whole minute, so a late start on the committee's signal costs you nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
