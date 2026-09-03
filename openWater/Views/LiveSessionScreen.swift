import MapKit
import OpenWaterCore
import SwiftUI

/// The screen while a session is recording.
///
/// A phone on the water is in a pouch on a harness, under an armband, or in a
/// wetsuit — glanced at, not read. So the current speed is enormous and
/// everything else is secondary, and the controls are large enough to hit with
/// cold, wet hands through a sheet of plastic.
struct LiveSessionScreen: View {

    /// Called when the rider ends the session. There is no confirmation: the
    /// question "are you sure?" had one answer, and ending is not destructive
    /// now that the session always saves — the debrief opens on top of it.
    var onEnd: () -> Void

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(AppSettings.self) private var settings

    /// Room the floating tab bar takes. End and Pause clear it explicitly
    /// rather than trusting a safe-area inset to reach this far.
    @Environment(\.floatingTabBarHeight) private var tabBarHeight

    /// Whether the live map is showing. On by default: the space it fills was
    /// empty, and a rider mid-session wants to see where they have been —
    /// which runs were the fast ones, and where they are relative to the
    /// launch. Collapsible for anyone who wants the speed and nothing else.
    @AppStorage("liveMapVisible") private var showMap = true

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            Text(Format.speed(
                recorder.metrics.currentSpeed,
                unit: settings.units.speed,
                decimals: 1,
                includeSymbol: false
            ))
            .font(.system(size: 108, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .foregroundStyle(recorder.state == .paused ? .secondary : .primary)
            .contentTransition(.numericText())

            Text(settings.units.speed.symbol)
                .font(.headline)
                .foregroundStyle(.secondary)

            if recorder.state == .paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.top, 6)
            }

            // A build without the location background mode records perfectly
            // until the screen locks and then stops, and the rider finds out
            // afterwards. That has shipped once. It is a packaging mistake with
            // no runtime symptom, so the only defence is saying it out loud
            // while there is still time to keep the screen on.
            if !recorder.location.supportsBackgroundRecording {
                Label("This build stops recording when the screen locks",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }

            // A grant revoked from Settings or Control Centre mid-session
            // used to be invisible: fixes stopped arriving, the clock kept
            // running, and the speed sat frozen at its last value until the
            // rider stopped and found a track that ended an hour ago.
            if recorder.location.authorization == .denied || recorder.location.authorization == .restricted {
                Label("Location access is off — nothing is being recorded. Turn it back on in Settings.",
                      systemImage: "location.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            } else if recorder.location.isReducedAccuracy {
                Label("Precise Location is off — the track will be kilometres coarse. Turn it on in Settings ▸ openWater.",
                      systemImage: "location.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }

            if showMap {
                // Capped rather than greedy: past about a third of the screen
                // the map stops telling you anything new and starts squeezing
                // the numbers, which are what a glance is actually for.
                liveMap
                    .frame(maxHeight: 300)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            } else {
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) { showMap = true }
                } label: {
                    Label("Show map", systemImage: "map")
                        .font(.subheadline)
                }
                Spacer(minLength: 0)
            }

            grid
                .padding(.horizontal)
                .padding(.top, 10)

            if let record = recorder.recordsHit.first {
                Label(
                    "New best \(record.category.shortName): \(Format.speed(record.speed, unit: settings.units.speed))",
                    systemImage: "trophy.fill"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.yellow)
                .padding(.top, 12)
            }

            Spacer(minLength: 0)

            // Clear of the tab bar by its full height, plus a gap. End and
            // Pause are the two controls that must never be covered — a rider
            // who cannot stop a recording has lost the session — and a wet
            // thumb aiming for End should not be able to land on Settings.
            controls
                .padding(.horizontal)
                .padding(.bottom, tabBarHeight + 10)
        }
        // This screen is read at arm's length with spray on the glass, and its
        // legibility comes from the tiles sitting in a tight block under the
        // speed. Left to fill an iPad they string out into one long row —
        // eight glances instead of one — so the whole column keeps a phone's
        // proportions and centres itself in the window.
        .frame(maxWidth: 600)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
            SummaryTile(label: "Max", value: Format.speed(
                recorder.metrics.maxSpeed, unit: settings.units.speed, decimals: 1, includeSymbol: false
            ))
            SummaryTile(label: "10 s", value: Format.speed(
                recorder.metrics.current10s, unit: settings.units.speed, decimals: 1, includeSymbol: false
            ))
            SummaryTile(label: "Distance", value: Format.distance(
                recorder.metrics.distance, unit: settings.units.distance
            ))
            SummaryTile(label: "Time", value: Format.duration(recorder.metrics.duration))
            SummaryTile(label: "Runs", value: "\(recorder.metrics.runCount)")
            if recorder.sport.isFoiling {
                SummaryTile(label: "On foil", value: Format.duration(recorder.metrics.timeOnFoil))
            }
            SummaryTile(label: "Best 500 m", value: {
                let best = recorder.metrics.best(.distance(metres: 500))
                return best > 0
                    ? Format.speed(best, unit: settings.units.speed, decimals: 1, includeSymbol: false)
                    : "—"
            }())
            // Accuracy *and* rate: the two independent ways GPS can be letting
            // a session down, and a rider who says "it feels slow" needs to be
            // able to see which one it is.
            SummaryTile(label: "GPS", value: recorder.metrics.horizontalAccuracy >= 0
                ? String(format: "±%.0f m", recorder.metrics.horizontalAccuracy)
                : "—")
            SummaryTile(label: "Fix rate", value: recorder.metrics.fixInterval
                .map { String(format: "%.1f s", $0) } ?? "—")
        }
    }

    /// Where you have been, live.
    ///
    /// Deliberately not interactive — no gestures, no run selection. A rider
    /// reading this is on the water with one hand free; anything that can be
    /// panned out of position by a wet thumb and then has to be panned back is
    /// worse than useless. Tapping it collapses it, and that is the only thing
    /// it does.
    private var liveMap: some View {
        Map(position: $camera, interactionModes: []) {
            UserAnnotation()
            let coordinates = recorder.trackCoordinates
            if coordinates.count > 1 {
                MapPolyline(coordinates: coordinates)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
        }
        .mapStyle(settings.mapStyle.mapStyle)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.snappy) { showMap = false }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
            }
            .padding(8)
            .accessibilityLabel("Hide map")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if recorder.state == .paused {
                Button {
                    recorder.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            } else {
                Button {
                    recorder.pause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            }

            Button(action: onEnd) {
                Label("End", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .font(.headline)
    }
}
