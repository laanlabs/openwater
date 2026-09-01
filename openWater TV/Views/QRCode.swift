import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// A link, as something you can point a phone at.
///
/// The one bridge a television has to the rest of the internet. tvOS has no
/// browser, no share sheet and no clipboard worth the name, so a page an Apple
/// TV cannot open is not a dead end — it is a code on the screen and a phone
/// already in the room.
enum QRCode {

    /// Render `text` as a QR image, or nil if Core Image will not.
    ///
    /// Drawn small and scaled up with nearest-neighbour, which is how a QR
    /// wants to be enlarged: the generator emits one pixel per module, and
    /// any smoothing filter turns crisp squares into grey mush a camera has
    /// to work at. `.M` correction, the default, survives a television's
    /// reflections without spending a quarter of the code on redundancy.
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// The code itself, on the white it needs.
///
/// A QR reads as dark-on-light; on this app's dark chrome the generator's own
/// transparent background would leave white modules invisible, so the card is
/// part of the picture rather than decoration around it.
struct QRCodeCard: View {

    let link: URL
    var side: CGFloat = 380

    var body: some View {
        Group {
            if let image = QRCode.image(for: link.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: side, height: side)
            } else {
                // Core Image refused — a URL long past what a QR can hold, or
                // a simulator without the filter. Say so rather than showing
                // an empty white square somebody will stand there scanning.
                Image(systemName: "qrcode")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(.black.opacity(0.3))
                    .frame(width: side, height: side)
            }
        }
        .padding(30)
        .background(.white, in: RoundedRectangle(cornerRadius: 28))
        .accessibilityLabel("QR code for \(link.absoluteString)")
    }
}
