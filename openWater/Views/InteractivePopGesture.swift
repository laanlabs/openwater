import SwiftUI

/// Turns the swipe-from-the-left-edge back gesture off for a screen that needs
/// that edge for itself.
///
/// The trim bar's start handle sits at the very left of the chart, which is
/// inside the system's edge-swipe zone — so reaching for it popped the session
/// instead of dragging the handle. There is no SwiftUI modifier for this, so
/// this reaches the `UINavigationController` the hosting controller is in and
/// toggles its recogniser.
///
/// Scoped rather than global, and re-enabled on the way out: back-swipe is a
/// gesture people rely on everywhere else, and a screen that silently keeps it
/// switched off after you leave is worse than the problem it solves.
struct InteractivePopGesture: UIViewControllerRepresentable {

    var isEnabled: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isEnabled = isEnabled
    }

    final class Controller: UIViewController {

        var isEnabled = true {
            didSet { apply() }
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Whatever happens, the rest of the app gets its gesture back.
            navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        }

        private func apply() {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = isEnabled
        }
    }
}

extension View {
    /// Disable the back-swipe while `enabled` is false.
    func interactivePopGesture(enabled: Bool) -> some View {
        background(
            InteractivePopGesture(isEnabled: enabled)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}
