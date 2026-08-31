import UIKit

/// The flow map's colours, two ramps for two jobs.
///
/// The wash wears the classic wind-map ramp every forecaster's map has
/// taught riders to read — white through lavender and cyan for the calms,
/// greens through the working range, yellow to orange to red as it gets
/// serious — in fine bands, because "8 or 11" is exactly the distinction a
/// rider is squinting for. The arrow ramp is the app's own coarser
/// thresholds, used when the wash is off and the arrows carry the colour
/// themselves.
public nonisolated enum WindPalette: Sendable {

    /// The wash bands, knots. Pale colours for light air on purpose: a
    /// calm should let the map show through, not sit on it like a slab.
    public static let washBands: [(upTo: Double, colour: UIColor)] = [
        (2, UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1)),
        (4, UIColor(red: 0.90, green: 0.88, blue: 0.97, alpha: 1)),
        (6, UIColor(red: 0.82, green: 0.94, blue: 0.97, alpha: 1)),
        (8, UIColor(red: 0.69, green: 0.92, blue: 0.89, alpha: 1)),
        (10, UIColor(red: 0.60, green: 0.90, blue: 0.68, alpha: 1)),
        (12, UIColor(red: 0.36, green: 0.85, blue: 0.46, alpha: 1)),
        (14, UIColor(red: 0.20, green: 0.78, blue: 0.36, alpha: 1)),
        (16, UIColor(red: 0.56, green: 0.84, blue: 0.22, alpha: 1)),
        (18, UIColor(red: 0.95, green: 0.90, blue: 0.25, alpha: 1)),
        (20, UIColor(red: 0.96, green: 0.76, blue: 0.19, alpha: 1)),
        (22, UIColor(red: 0.96, green: 0.60, blue: 0.17, alpha: 1)),
        (25, UIColor(red: 0.93, green: 0.42, blue: 0.19, alpha: 1)),
        (28, UIColor(red: 0.85, green: 0.22, blue: 0.16, alpha: 1)),
        (32, UIColor(red: 0.80, green: 0.13, blue: 0.34, alpha: 1)),
    ]

    public static func washColour(for kn: Double) -> UIColor {
        for band in washBands where kn < band.upTo { return band.colour }
        return UIColor(red: 0.76, green: 0.09, blue: 0.55, alpha: 1)
    }

    /// Each band's colour anchored at the band's own midpoint — the stops a
    /// continuous read of this palette interpolates between.
    public static let smoothStops: [(at: Double, colour: UIColor)] = {
        var previous = 0.0
        return washBands.map { band in
            defer { previous = band.upTo }
            return ((previous + band.upTo) / 2, band.colour)
        }
    }()

    /// The palette read as a gradient rather than as bands.
    ///
    /// The map's wash wants this so the field reads as one surface, and the
    /// conditions strip wants it so two neighbouring hours a knot apart do
    /// not jump a whole colour at each other. One implementation, because
    /// two would drift and the whole point of the ramp is that green means
    /// the same thing everywhere in the app.
    public static func smooth(for kn: Double) -> UIColor {
        guard let first = smoothStops.first, let last = smoothStops.last else { return .clear }
        if kn <= first.at { return first.colour }
        if kn >= last.at { return last.colour }
        for index in 1..<smoothStops.count where kn < smoothStops[index].at {
            let a = smoothStops[index - 1], b = smoothStops[index]
            return lerp(a.colour, b.colour, (kn - a.at) / (b.at - a.at))
        }
        return last.colour
    }

    public static func lerp(_ a: UIColor, _ b: UIColor, _ t: Double) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t, green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t, alpha: 1)
    }

    /// The arrows when the wash is carrying the colour: dark slate streaks
    /// over the field, the way the reference maps draw them.
    public static let arrowNeutral = UIColor(white: 0.24, alpha: 1)

    /// The coarser app-threshold ramp for wash-off arrows.
    public static func colour(for kn: Double) -> UIColor {
        switch kn {
        case ..<8: .systemGray
        case ..<12: .systemTeal
        case ..<15: UIColor(named: "AccentColor") ?? .systemBlue
        case ..<21: .systemOrange
        default: .systemPink
        }
    }
}
