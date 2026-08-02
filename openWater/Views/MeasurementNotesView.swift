import OpenWaterCore
import SwiftUI

/// How every headline number on this session was arrived at.
///
/// Written because two apps fed the same afternoon disagree, and a rider
/// staring at "avg 9.8" here and "avg 5.8" there has no way to tell which is
/// wrong — or that neither is, and they are answering different questions.
/// Nearly every difference between GPS session apps comes down to four choices
/// nobody publishes: which clock the average is over, whether speed comes from
/// Doppler or from positions, how strictly bad fixes are thrown out, and
/// whether a gap in the recording is bridged with a straight line.
///
/// So this screen states openWater's choice for each, and shows the numbers
/// *from this session* that the choice produced — the fixes actually dropped,
/// the seconds actually lost. A claim with the workings attached can be checked
/// and argued with. A number on its own can only be believed or not.
struct MeasurementNotesView: View {

    /// Where the numbers come from.
    ///
    /// A detail screen already has the decoded session; the list has only the
    /// denormalised row and must decode one. Both reach the same explanation,
    /// because the question is asked from both places.
    enum Source {
        case loaded(Session, SessionSummary)
        case stored(StoredSession)
    }

    let source: Source

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var resolved: (session: Session, summary: SessionSummary)?

    init(session: Session, summary: SessionSummary) {
        source = .loaded(session, summary)
        _resolved = State(initialValue: (session, summary))
    }

    init(stored: StoredSession) {
        source = .stored(stored)
    }

    private var units: UnitPreferences { settings.units }

    var body: some View {
        NavigationStack {
            Group {
                if let resolved {
                    content(session: resolved.session, summary: resolved.summary)
                } else {
                    ProgressView("Reading the session…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemGroupedBackground))
                }
            }
            .navigationTitle("How this was measured")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                guard resolved == nil, case .stored(let stored) = source else { return }
                // Decoding a season-long archive is not list-row work, so it
                // happens here, once, off the main actor.
                let data = stored.archiveData
                let loaded = await Task.detached(priority: .userInitiated) {
                    try? SessionArchive.decode(data).session
                }.value
                if let loaded, let summary = loaded.summary {
                    resolved = (loaded, summary)
                }
            }
        }
    }

    @ViewBuilder
    private func content(session: Session, summary: SessionSummary) -> some View {
        let quality = summary.quality
        List {
            intro
            durationSection(session: session, summary: summary)
            averageSection(summary: summary)
            maxSpeedSection(summary: summary)
            distanceSection(session: session, summary: summary, quality: quality)
            fixesSection(session: session, summary: summary, quality: quality)
            comparisonSection
        }
    }

    // MARK: - Sections

    private var intro: some View {
        Section {
            Text("Every figure below comes from the samples still on this device. Nothing here is rounded up, and each one says what it counted and what it left out.")
                .font(.callout)
        }
    }

    private func durationSection(session: Session, summary: SessionSummary) -> some View {
        Section {
            row("Total time", Format.duration(summary.duration))
            row("Moving time", Format.duration(summary.movingTime))
            row("Stopped", Format.duration(max(0, summary.duration - summary.movingTime)))
        } header: {
            Text("Duration")
        } footer: {
            Text("""
            Total time is the last fix minus the first, including every pause. Moving time counts only the samples above \(Format.speed(session.sport.thresholds.movingSpeed, unit: units.speed, decimals: 1)) — sitting on the board waiting for wind is not time spent riding.

            The session list shows total time. Apps that show a shorter figure are usually showing moving time, and apps that show a longer one are counting from when you pressed start rather than from your first usable fix.
            """)
        }
    }

    private func averageSection(summary: SessionSummary) -> some View {
        Section {
            row("Average moving", Format.speed(summary.averageMovingSpeed, unit: units.speed, decimals: 1))
            row("Average overall", Format.speed(summary.averageSpeed, unit: units.speed, decimals: 1))
        } header: {
            Text("Average speed")
        } footer: {
            Text("""
            Two honest answers to two different questions. Average moving is distance ÷ moving time: how fast you went when you were going. Average overall is distance ÷ total time, so every minute spent drifting or walking back up the beach drags it down.

            openWater shows the moving average, because on a foil most of a session is spent not moving and an overall average mostly measures how long you rested. This is the single biggest reason two apps disagree about the same ride — check which one each is showing before assuming either is wrong.
            """)
        }
    }

    private func maxSpeedSection(summary: SessionSummary) -> some View {
        Section {
            row("Peak sample", Format.speed(summary.maxSpeed, unit: units.speed, decimals: 1))
            if let best2s = summary.result(for: .time(seconds: 2)), best2s.isValid {
                row("Best 2 seconds", Format.speed(best2s.speed, unit: units.speed, decimals: 1))
            }
            if let best10s = summary.result(for: .time(seconds: 10)), best10s.isValid {
                row("Best 10 seconds", Format.speed(best10s.speed, unit: units.speed, decimals: 1))
            }
            row("Speed came from", summary.speedSource.displayName)
        } header: {
            Text("Top speed")
        } footer: {
            Text(maxSpeedExplanation(summary))
        }
    }

    private func maxSpeedExplanation(_ summary: SessionSummary) -> String {
        var text = ""
        switch summary.speedSource {
        case .doppler:
            text += "Your device reported speed directly, measured from the Doppler shift of the satellite signals rather than worked out from how far you moved. It is the better measurement by a wide margin: it does not care that two positions were twenty metres apart when one of them was wrong.\n\n"
        case .derived, .mixed:
            text += "This track carried no usable Doppler speed, so speeds were worked out from the distance between fixes and the time between them. That is more sensitive to position noise, and a single bad fix can invent a spike — treat the peak as indicative.\n\n"
        }
        text += "The peak sample is the single fastest instant, after a Kalman filter weighted by the receiver's own confidence in each reading. Smoothing is what stops one noisy sample becoming a personal best; it also means the peak here can sit a little under a raw, unfiltered figure from another app.\n\nThe 2-second and 10-second figures are averages over a window, which is what speedsurfing results are quoted in. They are always lower than the peak and much harder to fluke."
        return text
    }

    private func distanceSection(session: Session, summary: SessionSummary, quality: TrackQuality) -> some View {
        Section {
            row("Distance", Format.distance(summary.distance, unit: units.distance))
            row("Fixes used", "\(session.track.count)")
            if quality.dropoutCount > 0 {
                row("Gaps in the recording",
                    "\(quality.dropoutCount) · \(Format.shortDuration(quality.dropoutDuration))")
            }
        } header: {
            Text("Distance")
        } footer: {
            Text("""
            Added up leg by leg between consecutive fixes, along the curve of the earth. It is not the straight line from start to finish, and it is not smoothed.

            Where the recording has a hole longer than 30 seconds, that leg contributes nothing. Drawing a straight line across a gap adds distance nobody sailed and hands the speed windows a leg at a speed nobody did. Apps that bridge gaps report more distance than you covered\(quality.dropoutCount > 0 ? " — on this session there \(quality.dropoutCount == 1 ? "was 1 such gap" : "were \(quality.dropoutCount) such gaps"), totalling \(Format.shortDuration(quality.dropoutDuration))." : ", though this session has none.")
            """)
        }
    }

    private func fixesSection(session: Session, summary: SessionSummary, quality: TrackQuality) -> some View {
        Section {
            row("GPS quality", "\(Int(quality.score)) · \(quality.grade.displayName)")
            row("Average accuracy", String(format: "±%.0f m", quality.meanAccuracy))
            if let limit = quality.accuracyLimitUsed {
                row("Accuracy limit used", String(format: "±%.0f m", limit))
            }
            row("Fix rate", String(format: "%.2f per second", quality.fixRate))
            ForEach(rejectionCounts(session), id: \.reason) { entry in
                row(entry.reason, "\(entry.count)")
            }
        } header: {
            Text("What was thrown away")
        } footer: {
            Text(fixesExplanation(session, quality))
        }
    }

    private func fixesExplanation(_ session: Session, _ quality: TrackQuality) -> String {
        var text = "A fix is dropped if it has no usable position, if its accuracy is worse than the limit for this recording, if the speed is physically impossible for the sport, or if reaching it from the previous fix would need a speed nothing can do — the classic GPS teleport.\n\n"
        if let limit = quality.accuracyLimitUsed,
           limit > session.sport.thresholds.maxHorizontalAccuracy {
            text += String(
                format: "The accuracy limit here was relaxed to ±%.0f m, from the usual ±%.0f m. Your device reported soft fixes for most of this session — holding it to the strict figure would have deleted most of the recording rather than cleaned it up. The track and the distance are still right; treat the peak speeds as indicative.\n\n",
                limit, session.sport.thresholds.maxHorizontalAccuracy
            )
        }
        text += "Every rejected sample is kept in the file, so this can be checked rather than taken on trust. Export the session as an openWater archive to see them."
        return text
    }

    private var comparisonSection: some View {
        Section {
            Text("""
            Same afternoon, different numbers? In order of how much they usually matter:

            **Which clock.** A moving average and an overall average of the same ride can differ by half. See above for both.

            **Where the session starts and ends.** Some apps begin timing when you press start, openWater begins at your first usable fix and ends at the last one.

            **How strictly fixes are filtered.** A permissive app keeps noisy samples, which inflates both distance and top speed. A strict one throws away real riding. openWater's limits are per sport and are listed above.

            **Whether gaps are bridged.** Straight lines across dropouts add distance that was never sailed.

            **Smoothing.** A raw peak sample is always higher than a filtered one, and always less trustworthy.

            None of these make one app right and another wrong. They make the numbers answers to different questions — which is why openWater shows you which question it answered.
            """)
            .font(.callout)
        } header: {
            Text("Why another app shows something else")
        }
    }

    // MARK: - Parts

    private func rejectionCounts(_ session: Session) -> [(reason: String, count: Int)] {
        Dictionary(grouping: session.track.rejections, by: \.reason)
            .map { (reason: $0.key.displayName, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}
