import OpenWaterCore
import PhotosUI
import SwiftUI

/// Fix a spot, or add one — standing on it, or pointing at it on the map.
///
/// The website has the same form; the app's advantage is that the rider is
/// often *there*: the camera is in their hand and the GPS knows where "here"
/// is, so a new spot's pin places itself and a correction's photo is thirty
/// seconds old. But "there" is not the only case — a spot remembered from last
/// season, or the far end of a downwinder you have never stood at, both want a
/// pin dropped on a map. So every pin here starts from the best guess
/// available and stays movable. Everything goes to the same review queue the
/// site feeds — nothing a rider submits appears in the guide until a human has
/// looked at it.
struct SuggestSpotView: View {

    enum Mode {
        case correction(GuideSpot)
        /// A place already chosen — from the map — or `nil` to use the fix.
        case newSpot(PickedPlace?)
    }

    let mode: Mode

    @Environment(PhoneRecorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "photo"
    @State private var name = ""
    @State private var activities: Set<String> = []
    @State private var details = ""
    @State private var links = ""
    @State private var contact = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [UIImage] = []
    @State private var showingCamera = false
    @State private var isSubmitting = false
    @State private var submitted = false
    @State private var errorMessage: String?

    /// Where the spot is — the launch, and for a run, where it ends.
    @State private var launch: PickedPlace?
    @State private var landing: PickedPlace?
    @State private var picking: PinTarget?
    @State private var seeded = false

    enum PinTarget: String, Identifiable {
        case launch, landing
        var id: String { rawValue }
    }

    private static let activityOptions = [
        "Wing Foiling", "Prone Foiling", "Parawinging", "SUP Foiling",
        "Downwind Foiling", "Windsurfing", "Kite Foiling",
    ]

    private static let kinds: [(id: String, label: String, prompt: String)] = [
        ("photo", "Photo", "Anything worth knowing about the photos — where they're taken from, what the conditions were."),
        ("correction", "Fix info", "Conditions, best wind, season, hazards, launch and parking — anything the page gets wrong or misses."),
        ("location", "Adjust location", "Say what's wrong with the pin — parking is on the other side, the beach access moved, the takeout is round the headland."),
        ("wind", "Wind meter", "Where is the meter, who runs it? Paste a link below."),
        ("camera", "Webcam", "Where is the camera, what does it show? Paste a link below."),
    ]

    private var isCorrection: Bool {
        if case .correction = mode { return true }
        return false
    }

    private var spot: GuideSpot? {
        if case .correction(let spot) = mode { return spot }
        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if submitted {
                    thanks
                } else {
                    form
                }
            }
            .navigationTitle(isCorrection ? "Improve This Spot" : "Add a Spot")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Suggest a spot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !submitted {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Button("Submit") { submit() }
                                .fontWeight(.semibold)
                                .disabled(!canSubmit)
                        }
                    }
                }
            }
        }
        .toolLocation(recorder)
        .onAppear(perform: seed)
        .sheet(item: $picking) { target in
            LocationPickerSheet(
                title: target == .launch ? "Where is the launch?" : "Where does it land?",
                initial: (target == .launch ? pinnedLaunch : landing ?? pinnedLaunch)?.coordinate
            ) { place in
                switch target {
                case .launch:
                    launch = place
                    if !isCorrection, name.isEmpty { name = place.name }
                case .landing:
                    landing = place
                }
            }
        }
        .alert("Couldn't submit", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Start each pin from the best guess there is: the spot being corrected,
    /// the place picked on the map, or — failing both — wherever the phone
    /// says it is. Once, so a rider who moves a pin does not have it moved
    /// back under them by a late GPS fix.
    private func seed() {
        guard !seeded else { return }
        switch mode {
        case .correction(let spot):
            launch = PickedPlace(name: spot.name,
                                 latitude: spot.latitude, longitude: spot.longitude)
        case .newSpot(let place):
            if let place {
                launch = place
                if name.isEmpty { name = place.name }
            }
        }
        seeded = true
    }

    /// The launch pin, falling back to the live fix while nothing is chosen.
    private var pinnedLaunch: PickedPlace? {
        if let launch { return launch }
        guard let here = recorder.location.lastCoordinate else { return nil }
        return PickedPlace(name: "", coordinate: here)
    }

    /// Has the rider actually moved the pin? Twenty metres is well inside a
    /// car park and well outside GPS noise.
    private var movedLaunch: Bool {
        guard case .correction(let spot) = mode, let pinnedLaunch else { return false }
        return Geo.distance(pinnedLaunch.coordinate,
                            .init(latitude: spot.latitude, longitude: spot.longitude)) > 20
    }

    private var canSubmit: Bool {
        if isCorrection {
            // A location fix needs a change to describe: a moved pin, a
            // landing added, or words saying what is wrong. Otherwise the
            // site's rule — photos need photos, everything else needs words.
            if kind == "location" {
                return pinnedLaunch != nil && (movedLaunch || landing != nil || !details.isEmpty)
            }
            return kind == "photo" ? !photos.isEmpty : !details.isEmpty
        }
        return !name.isEmpty && pinnedLaunch != nil
    }

    // MARK: - Form

    private var form: some View {
        Form {
            if let spot {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spot.name)
                            .font(.headline)
                        Text(spot.where_)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("What's this about?", selection: $kind) {
                        ForEach(Self.kinds, id: \.id) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } else {
                Section {
                    TextField("Name — what locals call it", text: $name)
                    pinRow("Pin", place: pinnedLaunch, target: .launch)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(Self.activityOptions, id: \.self) { activity in
                                let on = activities.contains(activity)
                                Button {
                                    if on { activities.remove(activity) }
                                    else { activities.insert(activity) }
                                } label: {
                                    Text(activity)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .frame(height: 30)
                                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.systemGroupedBackground)),
                                                    in: Capsule())
                                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("New spot")
                } footer: {
                    Text("The pin starts where you're standing — submit from the launch and it places itself. Tap it to put it somewhere else on the map.")
                }
            }

            if isCorrection, kind == "location" { locationSection }

            Section {
                photoStrip
            } header: {
                Text("Photos")
            } footer: {
                Text("Up to 6, taken by you. By submitting you license them CC BY 4.0 for use in the guide.")
            }

            Section("Details") {
                TextEditor(text: $details)
                    .frame(minHeight: 90)
                if kind == "wind" || kind == "camera" || !isCorrection {
                    TextField("Links — one per line", text: $links, axis: .vertical)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                }
            }

            Section {
                TextField("Contact (optional)", text: $contact)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
            } footer: {
                Text(promptText + "\n\nEverything goes to review — nothing appears in the guide until a person has checked it.")
            }
        }
    }

    /// Both ends of a spot.
    ///
    /// A pin is a single point, which is fine for a lake and wrong for a
    /// downwinder: those have a launch you drive to and a landing you get
    /// picked up from, often miles apart, and the guide's one coordinate is
    /// only ever the first of them. Riders who have done the run know where
    /// the takeout is; this is where they say so.
    @ViewBuilder
    private var locationSection: some View {
        Section {
            pinRow("Launch", place: pinnedLaunch, target: .launch)

            if landing != nil {
                pinRow("Lands at", place: landing, target: .landing)
                Button("Remove the landing", role: .destructive) {
                    landing = nil
                }
                .font(.callout)
            } else {
                Button {
                    picking = .landing
                } label: {
                    Label("Add where a downwinder lands", systemImage: "mappin.and.ellipse")
                }
            }
        } header: {
            Text("Where it is")
        } footer: {
            Text(landing == nil
                 ? "Tap a pin to move the map under it. If this spot is a downwind run rather than a place you return to, add the landing as well — that's the end riders can never find."
                 : "Two pins, so the guide can show the run rather than a dot. Say in the details below which end needed fixing, and why.")
        }
    }

    /// A pin as a row: what it is, where it is, and an obvious way to move it.
    private func pinRow(_ title: String, place: PickedPlace?, target: PinTarget) -> some View {
        Button {
            picking = target
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let place {
                        Text(coordinates(place))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Finding you…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if place == nil {
                    ProgressView()
                }
                Image(systemName: "map")
                    .foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func coordinates(_ place: PickedPlace) -> String {
        let pin = String(format: "%.5f, %.5f", place.latitude, place.longitude)
        return place.name.isEmpty ? pin : "\(place.name) · \(pin)"
    }

    private var promptText: String {
        if isCorrection {
            return Self.kinds.first { $0.id == kind }?.prompt ?? ""
        }
        return "Conditions, best wind, season, hazards, parking — whatever a first-time visitor should know."
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button { showingCamera = true } label: {
                    strip(icon: "camera", label: "Camera")
                }
                .buttonStyle(.plain)

                PhotosPicker(selection: $photoItems, maxSelectionCount: 6, matching: .images) {
                    strip(icon: "photo.on.rectangle", label: "Library")
                }

                ForEach(Array(photos.enumerated()), id: \.offset) { index, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                photos.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .padding(3)
                        }
                }
            }
        }
        .onChange(of: photoItems) { _, items in
            Task {
                for item in items {
                    if photos.count >= 6 { break }
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        photos.append(image)
                    }
                }
                photoItems = []
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                if photos.count < 6 { photos.append(image) }
            }
            .ignoresSafeArea()
        }
    }

    private func strip(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .frame(width: 72, height: 72)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Submit

    private func submit() {
        isSubmitting = true
        let jpegs = photos.compactMap(SpotSuggestionClient.jpegForUpload)

        var submission = SpotSuggestionClient.Submission(type: isCorrection ? "correction" : "new-spot")
        if let spot {
            submission.kind = kind
            submission.spotId = spot.spotId
            submission.name = spot.name
            if kind == "location" { attachPins(to: &submission) }
        } else {
            submission.name = name
            submission.activities = activities.sorted().joined(separator: ", ")
            attachPins(to: &submission)
        }
        submission.details = details
        submission.links = links
        submission.contact = contact

        Task {
            do {
                try await SpotSuggestionClient.submit(submission, photos: jpegs)
                withAnimation(.snappy) { submitted = true }
            } catch {
                errorMessage = error.localizedDescription
            }
            isSubmitting = false
        }
    }

    /// Writes the pins into the submission the review queue already
    /// understands: `points` is the machine-readable pair, `location` the line
    /// a human reads. A spot with two ends is a `downwind` rather than a
    /// `launch`, which is the distinction the guide draws.
    private func attachPins(to submission: inout SpotSuggestionClient.Submission) {
        guard let launch = pinnedLaunch else { return }
        let pins = [launch] + (landing.map { [$0] } ?? [])
        submission.spotType = landing == nil ? "launch" : "downwind"
        submission.points = "[" + pins.map { "[\(rounded($0))]" }.joined(separator: ",") + "]"
        submission.location = zip(["Launch", "Lands at"], pins)
            .map { describe($0, $1) }
            .joined(separator: "\n")
    }

    /// Five decimal places is about a metre — more is false precision from a
    /// pin dropped by thumb.
    private func rounded(_ place: PickedPlace) -> String {
        let lat = (place.latitude * 1e5).rounded() / 1e5
        let lon = (place.longitude * 1e5).rounded() / 1e5
        return "\(lat),\(lon)"
    }

    private func describe(_ label: String, _ place: PickedPlace) -> String {
        let pin = String(format: "%.5f, %.5f", place.latitude, place.longitude)
        return place.name.isEmpty ? "\(label): \(pin)" : "\(label): \(place.name) (\(pin))"
    }

    private var thanks: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Thanks — it's in the queue")
                .font(.title3.weight(.bold))
            Text(isCorrection
                 ? "Your update goes to review and lands on the spot page once it's been checked."
                 : "Your spot goes to review and joins the guide once it's been checked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// The system camera, for the photo that is the whole point of doing this
/// from a phone standing at the spot.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// The Tools entry: works out where you are and offers the right form.
///
/// Standing at a known spot, the correction form for that spot is one tap;
/// standing somewhere the guide has never heard of, so is adding it. The
/// 2 km threshold is roughly "at the spot" versus "near the spot" — beyond
/// it we still offer the correction, we just stop presuming.
struct ImproveSpotHubView: View {

    @Environment(SpotGuideStore.self) private var guide
    @Environment(PhoneRecorder.self) private var recorder

    @State private var presenting: SuggestSpotView.Mode?

    private var nearest: (spot: GuideSpot, metres: Double)? {
        guard let here = recorder.location.lastCoordinate,
              let spot = guide.nearestSpot(to: here) else { return nil }
        let metres = Geo.distance(here, .init(latitude: spot.latitude, longitude: spot.longitude))
        return (spot, metres)
    }

    var body: some View {
        List {
            if let (spot, metres) = nearest {
                Section(metres < 2000 ? "You're at" : "Nearest spot") {
                    Button {
                        presenting = .correction(spot)
                    } label: {
                        HStack(spacing: 12) {
                            SpotThumb(url: spot.imageURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(spot.name)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Add photos or fix its info")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button {
                    presenting = .newSpot(nil)
                } label: {
                    Label("Add a new spot here", systemImage: "plus.circle")
                }
            } footer: {
                Text("Submissions go to the shared spot guide's review queue — the same one the website feeds. Nothing appears until it's been checked.")
            }
        }
        .navigationTitle("Add or Fix a Spot")
        .navigationBarTitleDisplayMode(.inline)
        .feedbackButton("Add or Fix a Spot")
        .toolLocation(recorder)
        .task { await guide.load() }
        .sheet(item: Binding(
            get: { presenting.map(PresentedMode.init) },
            set: { presenting = $0?.mode }
        )) { wrapped in
            SuggestSpotView(mode: wrapped.mode)
        }
    }

    /// `SuggestSpotView.Mode` carries a struct and isn't Identifiable; this
    /// wrapper is just enough identity for `.sheet(item:)`.
    private struct PresentedMode: Identifiable {
        let mode: SuggestSpotView.Mode
        var id: String {
            if case .correction(let spot) = mode { return spot.spotId }
            return "new"
        }
    }
}
