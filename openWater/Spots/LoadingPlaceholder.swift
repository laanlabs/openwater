import SwiftUI

/// A shape the size of the thing that is coming.
///
/// A spinner says "wait" and nothing else, and when it is replaced the layout
/// jumps because the real content is a different size. Weather screens fetch
/// half a dozen things at once from half a dozen services, so the result was
/// a page that shuffled itself for several seconds while each one landed.
///
/// A placeholder that already occupies the right space fixes both: nothing
/// moves when the data arrives, and the shimmer says the app is working
/// without claiming to know how long it will take.
struct LoadingPlaceholder: View {
    var height: CGFloat = 14
    var width: CGFloat? = nil
    var corner: CGFloat = 6

    @State private var shimmering = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(Color(.systemGray5))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .overlay {
                // A highlight travelling across, clipped to the shape. Cheap
                // enough to run on a dozen of these at once.
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color(.systemGray6).opacity(0.9), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.5)
                    .offset(x: shimmering ? geometry.size.width : -geometry.size.width * 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    shimmering = true
                }
            }
            .accessibilityLabel("Loading")
    }
}

/// The model comparison screen while its forecasts are in flight.
///
/// Shaped like the screen it becomes — a chart block, a legend row, a table —
/// so the real thing lands into the space already held for it.
struct ForecastLoadingPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LoadingPlaceholder(height: 12, width: 150)
            LoadingPlaceholder(height: 180, corner: 12)

            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    LoadingPlaceholder(height: 10, width: 54)
                }
                Spacer(minLength: 0)
            }

            LoadingPlaceholder(height: 12, width: 110)
            ForEach(0..<5, id: \.self) { _ in
                LoadingPlaceholder(height: 34, corner: 10)
            }
        }
        .padding()
        .transition(.opacity)
    }
}
