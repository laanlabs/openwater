import SwiftUI
import UIKit

/// The system share sheet, for a file that only exists once somebody asks
/// for it.
///
/// `ShareLink` wants its item up front, which for a session archive means
/// encoding a multi-megabyte file on the chance the menu gets opened. This
/// presents the same sheet — AirDrop included — from a URL written at the
/// moment of the tap.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file URL that can drive `.sheet(item:)`.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
