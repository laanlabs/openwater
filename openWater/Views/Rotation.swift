import SwiftUI
import UIKit

/// Portrait everywhere, landscape on a map.
///
/// This is a portrait app, and deliberately so: every card, list and scrubber
/// in it was drawn for one column, and a phone turned sideways on the Runs
/// list would only stretch a ruler across the screen. Maps are the exception.
/// A track, a wind field or a radar loop is a picture of a coastline, and a
/// coastline is wider than it is tall — turning the phone is the natural way
/// to ask for more of it.
///
/// So rotation is not opened app-wide. Screens that are worth reading sideways
/// ask for it while they are on display and hand it back when they leave, and
/// `UISupportedInterfaceOrientations` in the project stays portrait — this
/// gate is what the app delegate answers with instead.
@MainActor
final class OrientationGate {

    static let shared = OrientationGate()

    /// An iPad turns whichever way it likes, on every screen, and always has
    /// — its layouts were built for both. This gate is a phone's business.
    private let isPhone: Bool

    /// What the delegate reports right now.
    private(set) var mask: UIInterfaceOrientationMask

    private init() {
        isPhone = UIDevice.current.userInterfaceIdiom == .phone
        mask = isPhone ? .portrait : .all
    }

    /// How many screens on display have asked for landscape.
    ///
    /// A count rather than a flag because map screens hand over to each other:
    /// a full-screen map is retained before the screen underneath it is
    /// released, and a route pushed from one map to another overlaps the same
    /// way. A flag would be switched off by whichever screen left last.
    private var holders = 0

    func retain() {
        guard isPhone else { return }
        holders += 1
        guard mask != .allButUpsideDown else { return }
        mask = .allButUpsideDown
        publish()
    }

    func release() {
        guard isPhone else { return }
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        // Not on the spot. Leaving one map for another releases before the
        // new one retains, and a portrait lock applied in that gap spins the
        // phone upright and back again — which reads as the app dropping the
        // rotation and catching it. A beat's grace and the handover is
        // invisible; a real exit is still immediate to the eye.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard holders == 0, mask != .portrait else { return }
            mask = .portrait
            publish()
            returnToPortrait()
        }
    }

    /// Turn a sideways phone back upright.
    ///
    /// Only ever after `mask` has been narrowed and published: the system
    /// grants a geometry request and then immediately re-asks what the screen
    /// supports, so a request made while landscape is still allowed is undone
    /// within the frame.
    func returnToPortrait() {
        guard isPhone, let scene, scene.interfaceOrientation.isLandscape else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }

    /// Stand the interface back up while the phone itself is still on its side.
    ///
    /// Closing a full-screen map with the ✕ is the one case where the rider
    /// asks for the portrait screen back without turning the phone over. The
    /// map underneath still wants rotation — that is how it was opened — so
    /// landscape cannot simply be given up: the mask is narrowed for as long
    /// as it takes the rotation to land, and then handed straight back. The
    /// next turn of the phone opens the map again.
    func standUpright() {
        guard isPhone, let scene, scene.interfaceOrientation.isLandscape else { return }
        let allowed = mask
        mask = .portrait
        publish()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            // Only if a map screen is still on display; otherwise `release`
            // has the last word and portrait is where this should stay.
            guard holders > 0 else { return }
            mask = allowed
            publish()
        }
    }

    /// Make the system re-ask the delegate. Without this the mask changes and
    /// nothing happens until the phone is next turned.
    private func publish() {
        scene?.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// The only reason this app has a delegate: UIKit asks it, not the Info.plist,
/// which way a window may turn once the plist has said "portrait".
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationGate.shared.mask }
    }
}

// MARK: - The modifiers screens use

/// Let the phone turn while this screen is on display.
private struct AllowsLandscape: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { OrientationGate.shared.retain() }
            .onDisappear { OrientationGate.shared.release() }
    }
}

/// Turn the phone sideways and the map takes the whole screen.
///
/// The binding is whatever the screen already uses for its expand button, so
/// rotating and tapping arrive at exactly the same place — one full-screen
/// map, one piece of state, and a rider who found it either way can leave it
/// either way.
private struct FullScreenInLandscape: ViewModifier {

    @Binding var isFullScreen: Bool
    @Environment(\.verticalSizeClass) private var height

    func body(content: Content) -> some View {
        content
            .allowsLandscape()
            // Deliberately not `initial: true`. The screen may arrive with the
            // map already asked for — the screenshot route opens one — and an
            // initial pass would answer that with "you are in portrait, so
            // no". Only an actual turn of the phone is an instruction.
            .onChange(of: height) { _, now in
                withAnimation(.snappy) { isFullScreen = now == .compact }
            }
    }
}

/// A full-screen map that closes itself when the phone comes back upright.
///
/// The other half of `fullScreenInLandscape`, and its own half of the deal
/// too: a map opened by its button and then read sideways still gives the
/// screen back when the phone is stood up. Portrait means the page, landscape
/// means the map, whichever way the map was opened.
private struct ClosesInPortrait: ViewModifier {

    @Environment(\.verticalSizeClass) private var height
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .allowsLandscape()
            .onChange(of: height) { _, now in
                if now == .regular { dismiss() }
            }
            // Closed by its own button rather than by the phone being stood
            // up: the page underneath is a portrait page, so the interface
            // goes back to portrait with it.
            .onDisappear { OrientationGate.shared.standUpright() }
    }
}

extension View {

    /// Rotation is allowed while this screen is on display.
    func allowsLandscape() -> some View {
        modifier(AllowsLandscape())
    }

    /// Rotation is allowed, and turning the phone sideways sets `isFullScreen`
    /// — standing it back up clears it.
    func fullScreenInLandscape(_ isFullScreen: Binding<Bool>) -> some View {
        modifier(FullScreenInLandscape(isFullScreen: isFullScreen))
    }

    /// For the content of a full-screen map: rotation stays allowed, and the
    /// map dismisses itself when the phone is turned upright.
    func closesInPortrait() -> some View {
        modifier(ClosesInPortrait())
    }
}
