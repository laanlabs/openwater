import SwiftUI

/// "You got into this run without touching down."
///
/// Small and quiet on purpose. It appears on a majority of rows in a good
/// session, so anything louder would read as a warning; the information is
/// worth having and is not worth shouting.
struct LinkedChip: View {
    var body: some View {
        Label("linked", systemImage: "link")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.green)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.green.opacity(0.14), in: Capsule())
            .accessibilityLabel("Linked from the previous run without touching down")
    }
}
