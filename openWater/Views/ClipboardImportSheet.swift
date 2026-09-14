import OpenWaterCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Import a session from whatever is on the clipboard.
///
/// The file picker is the front door, and it is a door a lot of files never
/// reach: a GPX inside an email, an archive somebody pasted into a message, a
/// file on a share that the Files app cannot see. Every one of those can be
/// *copied*, and this is where a copy goes. The content is sniffed exactly
/// as a picked file is — `TrackImporter.detectFormat` — so a rider does not
/// have to know what they copied, only that they copied it.
///
/// **When the clipboard is empty, the sheet stays.** The obvious first
/// experience is opening this with nothing copied yet, and closing it in
/// their face would send them off to copy the file and then find their way
/// back through the menu. So it explains what to copy, waits, and re-reads
/// the clipboard by itself the moment the app comes back to the front — the
/// Paste button is for when it does not.
///
/// Reading the clipboard shows iOS's own "allow paste" prompt, so the sheet
/// does not read it on its own. Opening only *asks whether* there is
/// something there — `hasStrings`, `hasURLs`, the item count — which iOS
/// answers without a prompt, and says so; the read, and the prompt, come
/// when the rider taps Paste, the way every paste in every app works. Read
/// on appear, the prompt came up over the Sessions list before the sheet
/// had even finished sliding in.
struct ClipboardImportSheet: View {

    /// What was found: the bytes and what they turned out to be.
    let onImport: (Data, FileFormat) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    enum Found: Equatable {
        case nothing
        /// Something is there, and it has not been read yet.
        case unread
        /// The clipboard holds something, but not a track.
        case unrecognised(kind: String)
        case track(Data, FileFormat)
    }

    @State private var found: Found = .nothing
    @State private var hasLooked = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                switch found {
                case .track(let data, let format):
                    ready(data: data, format: format)
                case .unrecognised(let kind):
                    instructions(lead: "The clipboard holds \(kind), not a session file.")
                case .unread:
                    instructions(lead: "Something is on the clipboard — tap Paste to check it.")
                case .nothing:
                    instructions(lead: hasLooked ? "Nothing is on the clipboard yet." : nil)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("Import from clipboard")
            .navigationBarTitleDisplayMode(.inline)
            .feedbackButton("Import from clipboard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: peek)
            // Coming back from copying the file is the whole flow, so the
            // clipboard is checked again the moment the app is front — the
            // rider should see that it is there before they reach for Paste.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { peek() }
            }
        }
    }

    // MARK: - Found one

    private func ready(data: Data, format: FileFormat) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Found \(format == .openwater ? "an" : "a") \(format.displayName)")
                .font(.title3.weight(.semibold))
            Text("\(Self.size(data)) on the clipboard. Import it and the next screen confirms the sport, the same as a file.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onImport(data, format)
                dismiss()
            } label: {
                Text("Import")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
            Button("Look again", action: look)
                .font(.subheadline)
        }
    }

    // MARK: - Nothing yet

    private func instructions(lead: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let lead {
                Label(lead, systemImage: "clipboard")
                    .font(.subheadline.weight(.semibold))
            }
            Text("Copy a session file, then come back here.")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open the .gpx, .tcx, .csv or .openwater file wherever it is — Mail, Messages, Notes, a web page, the Files app.")
                step(2, "Copy it. In Files, touch and hold the file and choose Copy. In an email or a page, select the text and copy that.")
                step(3, "Switch back to openWater. This screen checks the clipboard on its own; tap Paste if it hasn't noticed.")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Button(action: look) {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
            Text("FIT files are binary and rarely copy as a file; use Import from Files for those.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(text)
        }
    }

    // MARK: - Reading the clipboard

    /// Whether there is anything to read, asked without reading it — iOS
    /// answers these without the paste prompt.
    private func peek() {
        // `-openWaterSeedClipboard <path>`: the app fills its own clipboard
        // from a file first. For screenshots and the UI harness — content
        // the app put there itself raises no paste prompt, and the prompt
        // is a system alert no test can answer.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-openWaterSeedClipboard"), index + 1 < arguments.count,
           let seed = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8) {
            UIPasteboard.general.string = seed
        }
        if case .track = found { return }
        let board = UIPasteboard.general
        found = board.hasStrings || board.hasURLs || board.numberOfItems > 0 ? .unread : .nothing
    }

    private func look() {
        hasLooked = true
        found = Self.read(UIPasteboard.general)
    }

    /// Whatever on the pasteboard reads as a track, in the order a copy is
    /// likely to have put it there.
    ///
    /// A file copied in the Files app arrives as data under the file's own
    /// type — `com.topografix.gpx`, `public.xml`, `public.json`, or just
    /// `public.data` — and sometimes only as a file URL. Text copied out of
    /// an email is a string. All of them are tried, and the first that the
    /// importer recognises wins; the type name is not trusted, the contents
    /// are.
    static func read(_ pasteboard: UIPasteboard) -> Found {
        var candidates: [Data] = []
        for item in pasteboard.items {
            for (type, value) in item {
                if let data = value as? Data { candidates.append(data) }
                else if let string = value as? String, let data = string.data(using: .utf8) { candidates.append(data) }
                else if let url = value as? URL {
                    if url.isFileURL, let data = try? Data(contentsOf: url) { candidates.append(data) }
                }
                _ = type
            }
        }
        if let string = pasteboard.string, let data = string.data(using: .utf8) {
            candidates.append(data)
        }
        for url in pasteboard.urls ?? [] where url.isFileURL {
            if let data = try? Data(contentsOf: url) { candidates.append(data) }
        }

        for data in candidates where !data.isEmpty {
            if let format = TrackImporter.detectFormat(data) {
                return .track(data, format)
            }
        }
        guard !candidates.isEmpty || pasteboard.numberOfItems > 0 else { return .nothing }
        let kind: String
        if pasteboard.hasImages { kind = "an image" }
        else if pasteboard.hasURLs, !(pasteboard.urls ?? []).contains(where: \.isFileURL) { kind = "a link" }
        else if pasteboard.hasStrings { kind = "text" }
        else { kind = "something else" }
        return .unrecognised(kind: kind)
    }

    private static func size(_ data: Data) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}
