import OpenWaterCore
import SwiftData
import SwiftUI

/// Where deleted sessions wait, in case the tap was a mistake.
///
/// A session is an afternoon on the water that cannot be recorded again, and
/// the delete control sits in the same menus as everything harmless. Asking
/// "are you sure?" does not help — the answer is always yes, including when it
/// should not be. Only keeping the data helps. So deleting moves a session
/// here, and here it stays for thirty days with its numbers still readable, so
/// a rider can recognise what they are about to lose before it goes.
struct RecentlyDeletedView: View {

    let sessions: [StoredSession]

    @Environment(SessionLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var pendingPurge: StoredSession?
    @State private var isConfirmingEmpty = false

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "Nothing deleted",
                    systemImage: "trash",
                    description: Text("Sessions you delete wait here for 30 days before they are gone for good.")
                )
            } else {
                List {
                    Section {
                        ForEach(sessions) { session in
                            row(session)
                        }
                    } footer: {
                        Text("Sessions are deleted for good 30 days after you remove them.")
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            if !sessions.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Empty", role: .destructive) { isConfirmingEmpty = true }
                }
            }
        }
        .confirmationDialog(
            "Delete everything here for good?",
            isPresented: $isConfirmingEmpty,
            titleVisibility: .visible
        ) {
            Button("Delete \(sessions.count) Session\(sessions.count == 1 ? "" : "s")", role: .destructive) {
                library.emptyTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Their tracks and every metric go with them. This cannot be undone.")
        }
        .confirmationDialog(
            "Delete for good?",
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingPurge { library.deletePermanently(pendingPurge) }
                pendingPurge = nil
            }
            Button("Cancel", role: .cancel) { pendingPurge = nil }
        } message: {
            Text("\"\(pendingPurge?.displayTitle ?? "")\" cannot be recovered afterwards.")
        }
    }

    /// Enough of the session to recognise it by — the point of the whole
    /// screen is deciding whether this is the one that should not have gone.
    private func row(_ session: StoredSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: session.sport.symbolName)
                        .foregroundStyle(.secondary)
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(Format.distance(session.distance, unit: settings.units.distance))
                    Text(Format.duration(session.duration))
                    Text("max \(Format.speed(session.maxSpeed, unit: settings.units.speed, decimals: 1))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(session.daysLeftInTrash == 0
                     ? "Deleted for good today"
                     : "\(session.daysLeftInTrash) day\(session.daysLeftInTrash == 1 ? "" : "s") left")
                    .font(.caption2)
                    .foregroundStyle(session.daysLeftInTrash <= 3 ? .orange : .secondary)
            }

            Spacer(minLength: 0)

            // A button, not a swipe. Somebody arrives here because something
            // went wrong, and a hidden gesture is the wrong thing to make them
            // guess at while a countdown runs.
            Button("Restore") { library.restore(session) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingPurge = session
            }
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") {
                library.restore(session)
            }
            Button("Delete for Good", systemImage: "trash", role: .destructive) {
                pendingPurge = session
            }
        }
    }
}
