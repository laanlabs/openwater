import CoreGraphics
import Foundation
import MapKit
import UIKit

/// The wash as one picture, instead of as hundreds of abutting quads.
///
/// **Why this exists.** The wash was drawn as a grid of `MapPolygon`s, and a
/// grid of translucent quads always shows its own grid: MapKit rasterizes each
/// one with antialiased edges, so where two meet, the shared pixels are either
/// painted twice or not quite once. Neither is the field's colour. That is the
/// faint lattice that has been over this map from the start, and it cannot be
/// tuned away — the correction quantises to whole pixels, so it steps from
/// overlap to gap without passing through nothing. Measured on a television:
/// +29 luma with no correction, +14 with the phone's, −3 at the best value
/// available, and never zero.
///
/// One image has no internal edges to get wrong. It is composited once,
/// translucency included, so there is nothing for a seam to be made of.
///
/// **It is also a better picture.** Quads draw a field of flat tiles; this
/// sample is bilinear at every pixel, so the wash comes out as the smooth
/// surface the model actually describes rather than a mosaic of it. The same
/// move that fixed the radar animation — stop handing the map many things and
/// hand it one — and for the same reason.
///
/// **What it gives up.** The bitmap is uniform in latitude and longitude, and
/// it is stretched onto a Mercator rectangle, where latitude is not uniform.
/// Over the spans a wash is drawn at — a few degrees at most — that is well
/// under a pixel of vertical drift, and a wash has no edge sharp enough to
/// show it. Over a continent it would; nothing draws one that big.
public struct WashRaster: Sendable {

    /// The picture, and the rectangle of the world it covers.
    public let image: CGImage
    public let region: MKCoordinateRegion
    /// The field this was made from, so a view can tell one raster from the
    /// next without comparing pixels.
    public let stamp: UUID

    /// How many pixels across the field's own grid is drawn.
    ///
    /// Deliberately modest. The field is a 7×9 model grid — there is no detail
    /// beyond it to resolve, and every pixel past that is interpolation the
    /// GPU does for free when it scales the image up. 512 across keeps the
    /// bilinear steps invisible at 4K while costing well under a megabyte.
    static let width = 512

    /// Render one hour of the field.
    ///
    /// `speeds` is the model grid in the layout's own order — row 0 southmost,
    /// which is why the rows are walked backwards here: a `CGImage` starts at
    /// the top, and the top of a map is north.
    ///
    /// Returns nil when nothing can be drawn, which is a real answer: an
    /// inland window under the ocean model has no water in it.
    static func render(speeds: [Double?],
                       columns: Int,
                       rows: Int,
                       layer: WashLayer,
                       mask: WaterMask,
                       region: MKCoordinateRegion,
                       stamp: UUID,
                       washAlpha: Double,
                       colour: (Double) -> UIColor) -> WashRaster? {
        guard columns > 1, rows > 1, speeds.count >= columns * rows else { return nil }

        // Square-ish pixels: the field is wider than it is tall in cells, and
        // a bitmap that ignored that would smear the interpolation one way.
        let width = Self.width
        let height = max(2, Int((Double(width) * Double(rows - 1) / Double(columns - 1)).rounded()))

        // The palette, resolved once into a table rather than per pixel.
        //
        // Two hundred thousand `UIColor`s an hour-change is an allocation and
        // a component read each, on a box that has already been reported
        // hanging. The ramp is continuous but a wash has no use for more than
        // a couple of hundred steps of it, and at that width the banding is
        // finer than the bitmap's own interpolation.
        let steps = 256
        let topKnots = 45.0
        var ramp = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: steps)
        for index in 0..<steps {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour(Double(index) / Double(steps - 1) * topKnots)
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            ramp[index] = (Double(r), Double(g), Double(b))
        }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var drewAnything = false

        // The feather, in the same terms the quads used: the outer fifth of
        // the field fades out, so the wash ends in a soft edge rather than a
        // painted wall at the fetch rectangle's border.
        let featherFraction = 0.14

        let south = region.center.latitude - region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2

        for y in 0..<height {
            // Top row is north, so the grid row runs the other way.
            let ty = 1 - Double(y) / Double(height - 1)
            let gy = ty * Double(rows - 1)
            let row0 = min(Int(gy), rows - 2)
            let fy = gy - Double(row0)
            let latitude = south + ty * region.span.latitudeDelta

            for x in 0..<width {
                let tx = Double(x) / Double(width - 1)
                let gx = tx * Double(columns - 1)
                let column0 = min(Int(gx), columns - 2)
                let fx = gx - Double(column0)

                // Bilinear over whatever answered. The ocean model returns nil
                // over land, so a sample straddling a shoreline keeps the
                // corners it has and reports how much of itself it could see —
                // the same rule the quads used, and what stops a coast being
                // drawn as a staircase of the sampling grid.
                let s00 = speeds[row0 * columns + column0]
                let s10 = speeds[row0 * columns + column0 + 1]
                let s01 = speeds[(row0 + 1) * columns + column0]
                let s11 = speeds[(row0 + 1) * columns + column0 + 1]
                let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
                let w01 = (1 - fx) * fy, w11 = fx * fy

                var total = 0.0, coverage = 0.0
                if let s = s00 { total += s * w00; coverage += w00 }
                if let s = s10 { total += s * w10; coverage += w10 }
                if let s = s01 { total += s * w01; coverage += w01 }
                if let s = s11 { total += s * w11; coverage += w11 }
                guard coverage > 0.001 else { continue }
                let knots = total / coverage

                let longitude = west + tx * region.span.longitudeDelta
                if mask.isWater(CLLocationCoordinate2D(latitude: latitude,
                                                       longitude: longitude)) == false { continue }

                // Distance to the nearest edge of the field, as a fraction of
                // the field. The quads counted this in rings of cells; in a
                // bitmap the same idea is simply how close to the border a
                // pixel is, which is one fewer thing to keep in step.
                let edge = min(min(tx, 1 - tx), min(ty, 1 - ty))
                let feather = min(1, edge / featherFraction)
                // A sample the model half-saw is painted half as strongly.
                let seen = min(1, (coverage - 0.25) / 0.45 + 0.25)
                let alpha = washAlpha * feather * max(0, seen)
                guard alpha > 0.002 else { continue }

                let shade = ramp[max(0, min(steps - 1,
                                            Int(knots / topKnots * Double(steps - 1))))]

                // Premultiplied, which is what the bitmap context below wants.
                let index = (y * width + x) * 4
                pixels[index]     = UInt8(max(0, min(255, shade.r * 255 * alpha)))
                pixels[index + 1] = UInt8(max(0, min(255, shade.g * 255 * alpha)))
                pixels[index + 2] = UInt8(max(0, min(255, shade.b * 255 * alpha)))
                pixels[index + 3] = UInt8(max(0, min(255, alpha * 255)))
                drewAnything = true
            }
        }

        guard drewAnything else { return nil }

        let space = CGColorSpaceCreateDeviceRGB()
        var data = pixels
        guard let context = CGContext(
            data: &data,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage()
        else { return nil }

        return WashRaster(image: image, region: region, stamp: stamp)
    }
}
