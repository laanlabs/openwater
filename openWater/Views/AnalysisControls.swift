import OpenWaterCore
import SwiftUI

/// The block that goes at the bottom of every screen showing analysis.
///
/// Three things belong together there, and they were previously either missing
/// or built once per screen:
///
/// 1. **What is missing.** Almost everything here is measured from the wind,
///    and a session very often has a direction and no strength, or neither.
///    A screen that quietly draws angles from an absent input is lying by
///    omission — it should say what it does not know, and offer the fix.
/// 2. **What the numbers mean.** Every threshold in this app was arrived at by
///    arguing with a real session, and none is a fact about the world. A rider
///    who disagrees should be able to move it and look, rather than file a bug
///    and wait.
/// 3. **Re-read it.** Analysis is cached with the session, so a change to the
///    wind, the sport or a threshold only lands when something asks for it.
///    That "something" used to be an edit or a trim, which is not a thing a
///    rider would think to do. Now it is a button that says what it does.
struct AnalysisFooter<Controls: View>: View {

    let session: Session
    let summary: SessionSummary

    /// What this particular screen's numbers are computed from. Only these are
    /// reported as missing — the Foiling screen has no business complaining
    /// about wind it does not use.
    var needs: Set<Requirement> = []

    var isBusy = false
    var onSetWind: () -> Void = {}
    let onReanalyse: () -> Void

    /// The thresholds this screen owns, if any.
    @ViewBuilder var controls: () -> Controls

    @State private var showsControls = false

    enum Requirement: Hashable {
        /// Which way the wind blew. Estimated from the track when it can be.
        case windDirection
        /// How hard. Never inferable — a track cannot tell you.
        case windSpeed
        /// The accelerometer, which is what separates working from gliding and
        /// finds jumps at all.
        case motionData
    }

    private var missing: [Requirement] {
        needs.filter { requirement in
            switch requirement {
            case .windDirection: session.effectiveWind == nil
            case .windSpeed: session.effectiveWind?.hasSpeed != true
            case .motionData: !summary.downwind.usedMotionData
            }
        }
        .sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(missing, id: \.self) { notice($0) }

            if Controls.self != EmptyView.self {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(.snappy) { showsControls.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showsControls ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("What counts, and what to change")
                                .font(.subheadline.weight(.medium))
                            Spacer(minLength: 0)
                            if !overrides.isEmpty {
                                Text("adjusted")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showsControls {
                        VStack(alignment: .leading, spacing: 16) {
                            controls()

                            if !overrides.isEmpty {
                                Button("Reset to the defaults for \(session.sport.displayName)",
                                       role: .destructive) {
                                    settings.sportOverrides[session.sport] = nil
                                    onReanalyse()
                                }
                                .font(.callout)
                            }

                            Text("These apply to every \(session.sport.displayName.lowercased()) session as it is analysed, not only this one.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            reanalyseButton
        }
        .cardChrome()
    }

    @Environment(AppSettings.self) private var settings

    private var overrides: SportThresholds.Overrides {
        settings.sportOverrides[session.sport] ?? .init()
    }

    /// Says what it will do, rather than "Refresh".
    private var reanalyseButton: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onReanalyse) {
                HStack(spacing: 8) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isBusy ? "Re-reading…" : "Re-read this session")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(isBusy)

            Text("Runs the whole analysis again from the recorded track. Worth doing after changing the wind, the sport, or anything above.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func notice(_ requirement: Requirement) -> some View {
        switch requirement {
        case .windDirection:
            NoWindCard(session: session, onSetWind: onSetWind)
        case .windSpeed:
            NoWindSpeedCard(compact: true, onSetWind: onSetWind)
        case .motionData:
            noticeCard(
                "No motion data in this session",
                detail: "The accelerometer is what separates working from gliding and finds jumps at all. An imported file rarely carries it; a session recorded on the watch or the phone does.",
                symbol: "waveform.path.ecg"
            )
        }
    }

    private func noticeCard(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension AnalysisFooter where Controls == EmptyView {
    init(
        session: Session,
        summary: SessionSummary,
        needs: Set<Requirement> = [],
        isBusy: Bool = false,
        onSetWind: @escaping () -> Void = {},
        onReanalyse: @escaping () -> Void
    ) {
        self.init(session: session, summary: summary, needs: needs, isBusy: isBusy,
                  onSetWind: onSetWind, onReanalyse: onReanalyse) { EmptyView() }
    }
}

private extension AnalysisFooter.Requirement {
    /// Worst first: not knowing the direction makes a screen wrong, not
    /// knowing the strength only makes it less useful.
    var order: Int {
        switch self {
        case .windDirection: 0
        case .windSpeed: 1
        case .motionData: 2
        }
    }
}

// MARK: - One threshold

/// A slider over one of the sport's detection thresholds.
///
/// Re-reads the session when the drag ends rather than on every frame of it —
/// the analysis is half a second of work on a long track.
struct ThresholdSlider: View {

    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double = 1
    let format: (Double) -> String
    let note: String
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text(format(value.wrappedValue))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step) { editing in
                if !editing { onCommit() }
            }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Editing a sport's thresholds

extension AppSettings {

    /// A binding onto one of a sport's overridable thresholds.
    ///
    /// Writing the default back clears the override rather than pinning it, so
    /// a rider who tries a value and puts it back is *following* the default
    /// again rather than frozen at today's value of it.
    func thresholdBinding(
        for sport: Sport,
        _ key: WritableKeyPath<SportThresholds.Overrides, Double?>,
        default fallback: Double
    ) -> Binding<Double> {
        Binding(
            get: { (self.sportOverrides[sport] ?? .init())[keyPath: key] ?? fallback },
            set: { newValue in
                var o = self.sportOverrides[sport] ?? .init()
                o[keyPath: key] = abs(newValue - fallback) < 0.0001 ? nil : newValue
                self.sportOverrides[sport] = o.isEmpty ? nil : o
            }
        )
    }
}

// MARK: - Re-running the analysis

/// Re-runs a session's analysis with the rider's current settings and saves it.
///
/// Shared because three screens now do it and they must agree: the result goes
/// back to the library, so the rest of the app shows what the screen shows
/// rather than the two drifting until the next launch.
@MainActor
enum SessionReanalyser {

    static func reanalyse(
        _ session: Session,
        settings: AppSettings,
        library: SessionLibrary
    ) async -> Session? {
        let categories = settings.categories
        let overrides = settings.overrides(for: session.sport)
        let edited = await Task.detached {
            session.applying(Session.Edits(session: session),
                             categories: categories, overrides: overrides)
        }.value
        guard edited.summary != nil else { return nil }
        library.save(edited)
        return edited
    }
}

// MARK: - Nothing to show

/// The screen behind a row that found nothing.
///
/// A row that vanishes when its count is zero is indistinguishable from a
/// feature that was never built, so every row stays and says "none found".
/// That only works if the screen behind it is worth the tap: it has to say
/// what was looked for, why none was found, and what would change the answer.
struct NothingFoundScreen: View {

    let title: String
    let headline: String
    let detail: String
    let session: Session
    let summary: SessionSummary
    var needs: Set<AnalysisFooter<EmptyView>.Requirement> = []
    var onSetWind: () -> Void = {}

    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @State private var isRecomputing = false
    @State private var current: Session?

    var body: some View {
        AnalysisDetail(title: title) {
            VStack(alignment: .leading, spacing: 8) {
                Label(headline, systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .cardChrome()

            AnalysisFooter(
                session: current ?? session,
                summary: summary,
                needs: needs,
                isBusy: isRecomputing,
                onSetWind: onSetWind,
                onReanalyse: reanalyse
            )
        }
    }

    private func reanalyse() {
        isRecomputing = true
        Task {
            current = await SessionReanalyser.reanalyse(current ?? session,
                                                        settings: settings, library: library)
            isRecomputing = false
        }
    }
}
