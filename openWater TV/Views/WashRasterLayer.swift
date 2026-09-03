import MapKit
import OpenWaterSpots
import SwiftUI

/// The wind wash, drawn as one image over the map.
///
/// The field used to be several hundred `MapPolygon`s, and a grid of
/// translucent quads always shows its own grid — see `WashRaster` for the
/// measurements. This places the single rendered picture instead: the field's
/// rectangle is projected through the map's own proxy, so the image lands
/// exactly where the quads used to and moves with the camera the same way.
///
/// `.interpolation(.high)` is the point of the whole exercise. The bitmap is
/// deliberately small — there is no detail in a 7×9 model grid to resolve
/// beyond it — and scaling it up smoothly is what turns a mosaic of cells into
/// the continuous surface the model actually describes.
struct WashRasterLayer: View {

    let raster: WashRaster
    let proxy: MapProxy

    var body: some View {
        // The two corners the image is stretched between. Nil when the
        // rectangle is entirely off screen, which is a real answer.
        let north = raster.region.center.latitude + raster.region.span.latitudeDelta / 2
        let south = raster.region.center.latitude - raster.region.span.latitudeDelta / 2
        let west = raster.region.center.longitude - raster.region.span.longitudeDelta / 2
        let east = raster.region.center.longitude + raster.region.span.longitudeDelta / 2

        if let topLeft = proxy.convert(CLLocationCoordinate2D(latitude: north, longitude: west),
                                       to: .local),
           let bottomRight = proxy.convert(CLLocationCoordinate2D(latitude: south, longitude: east),
                                           to: .local) {
            Image(decorative: raster.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: max(0, bottomRight.x - topLeft.x),
                       height: max(0, bottomRight.y - topLeft.y))
                .position(x: (topLeft.x + bottomRight.x) / 2,
                          y: (topLeft.y + bottomRight.y) / 2)
                // The field is fetched for a rectangle wider than the screen,
                // so most of this image is off the glass by design.
                .clipped()
        }
    }
}
