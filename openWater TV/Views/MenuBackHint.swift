import SwiftUI

/// A quiet "‹ Menu" hint at the top of any screen you can go into.
///
/// tvOS's Back button lives on the remote and nowhere on the glass, so a
/// screen you have pushed or covered gives no sign of how to leave it — you
/// are expected to know that Menu goes back. On a phone a swipe or a chevron
/// says so; a television says nothing. This is that missing sign: the same
/// chip in the same corner on every screen the app opens over another, so
/// "how do I get out of here" has one answer and it is always on screen.
///
/// A `safeAreaInset` rather than an overlay, so the content below is pushed
/// down clear of it rather than sliding under it — the hint never lands on a
/// title or the first row of a chart.
private struct MenuBackHint: ViewModifier {

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.backward")
                Text("Menu")
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: Capsule())
            .padding(.leading, 60)
            .padding(.top, 24)
        }
    }
}

extension View {
    /// Mark a screen as one you enter and leave with Menu. See `MenuBackHint`.
    func menuBackHint() -> some View { modifier(MenuBackHint()) }
}
