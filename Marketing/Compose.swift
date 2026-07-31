#!/usr/bin/env swift
//
// Composes App Store marketing screenshots.
//
// Each output is a full-bleed branded panel at the exact size Apple requires,
// with a headline, a supporting line, and the real app screenshot shown in a
// device frame below. Drawn with CoreGraphics rather than assembled by hand so
// the whole set regenerates from one command whenever the app's UI changes —
// hand-composited marketing art is stale the moment a screen moves.
//
// Usage: Compose.swift <raw-dir> <out-dir> <width> <height> <device>

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Brand

let navy = NSColor(srgbRed: 0.055, green: 0.133, blue: 0.322, alpha: 1)
let navyDeep = NSColor(srgbRed: 0.031, green: 0.078, blue: 0.208, alpha: 1)
let coral = NSColor(srgbRed: 0.925, green: 0.451, blue: 0.322, alpha: 1)
let cream = NSColor(srgbRed: 0.976, green: 0.973, blue: 0.965, alpha: 1)

struct Panel {
    let source: String
    let headline: String
    let subhead: String
    /// A call to action, shown as a coral pill at the foot of the panel.
    ///
    /// Only on the first and last panels. A CTA repeated on all eight reads as
    /// a banner ad and stops being noticed by the third; on the opener and the
    /// closer it lands at the two points where someone is actually deciding.
    var cta: String? = nil
}

let panels: [Panel] = [
    Panel(
        source: "02-map",
        headline: "Every speed that counts",
        subhead: "2 s, 5 × 10 s, 500 m, alpha, nautical mile — and any distance you add",
        cta: "Free · Open source · No account"
    ),
    Panel(
        source: "06-fullmap",
        headline: "See what actually happened",
        subhead: "Flights drawn bold, falls marked, one run at a time"
    ),
    Panel(
        source: "03-runs",
        headline: "Every run, unstacked",
        subhead: "One lane each, in time order — nothing overlapping"
    ),
    Panel(
        source: "05-playback",
        headline: "Replay the whole session",
        subhead: "Speed heatmap, live readout, scrub to any moment"
    ),
    Panel(
        source: "04-charts",
        headline: "Angles, gybes and time on foil",
        subhead: "Wind worked out from your own track — no signal needed"
    ),
    Panel(
        source: "07-records",
        headline: "Your record book",
        subhead: "Personal bests across every category, all time"
    ),
    Panel(
        source: "08-trends",
        headline: "Progress you can actually see",
        subhead: "Dry gybes and time on foil keep climbing after speed plateaus"
    ),
    Panel(
        source: "01-sessions",
        headline: "No account. No server.",
        subhead: "Works offline, exports everything, open source",
        cta: "Download openWater — free"
    ),
]

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 6 else {
    FileHandle.standardError.write(Data("usage: Compose.swift <raw> <out> <w> <h> <device>\n".utf8))
    exit(2)
}
let rawDirectory = URL(fileURLWithPath: args[1])
let outputDirectory = URL(fileURLWithPath: args[2])
let width = CGFloat(Int(args[3])!)
let height = CGFloat(Int(args[4])!)
let device = args[5]
let isPad = device == "ipad"

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// MARK: - Layout
//
// Everything scales off the canvas width so iPhone and iPad share one layout
// definition. The proportions are tuned for the iPhone and simply hold up on
// the larger canvas.

let s = width / 1320.0
let margin = 96 * s
let headlineSize = (isPad ? 92 : 104) * s
let subheadSize = (isPad ? 44 : 48) * s
let topPadding = (isPad ? 150 : 170) * s

// MARK: - Text

func attributed(
    _ string: String,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor,
    tracking: CGFloat = 0,
    lineSpacing: CGFloat = 0
) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = lineSpacing
    paragraph.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .kern: tracking,
        .paragraphStyle: paragraph,
    ])
}

func draw(_ text: NSAttributedString, in rect: CGRect) -> CGFloat {
    let bounding = text.boundingRect(
        with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    // Text is drawn from the top of `rect` downward, so the origin has to be
    // offset by the measured height — AppKit's coordinate space is y-up.
    let target = CGRect(
        x: rect.minX,
        y: rect.maxY - bounding.height,
        width: rect.width,
        height: bounding.height
    )
    text.draw(with: target, options: [.usesLineFragmentOrigin, .usesFontLeading])
    return bounding.height
}

// MARK: - Compose

func compose(_ panel: Panel, index: Int) {
    let sourceURL = rawDirectory.appendingPathComponent("\(panel.source).png")
    guard let shot = NSImage(contentsOf: sourceURL) else {
        print("  missing \(panel.source).png — skipped")
        return
    }

    // Render into an explicit bitmap at exactly the requested pixel size.
    //
    // `NSImage.lockFocus()` renders at the *display's* backing scale, so on a
    // Retina Mac it silently produces a 2640x5736 image when 1320x2868 was
    // asked for — and the App Store rejects anything that is not the exact
    // required dimensions.
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(width),
        pixelsHigh: Int(height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }
    rep.size = CGSize(width: width, height: height)

    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphicsContext.cgContext

    // Background: a vertical gradient in the icon's navy, so the whole set
    // reads as one family and the app icon sits naturally on top of it.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [navy.cgColor, navyDeep.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // A soft coral glow behind the device, to lift it off the background.
    context.saveGState()
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [coral.withAlphaComponent(0.30).cgColor,
                 coral.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: width / 2, y: height * 0.34),
        startRadius: 0,
        endCenter: CGPoint(x: width / 2, y: height * 0.34),
        endRadius: width * 0.75,
        options: []
    )
    context.restoreGState()

    // Headline and subhead, measured so the device sits below whatever height
    // the text actually took rather than at a guessed offset.
    var cursor = height - topPadding

    let headline = attributed(
        panel.headline,
        size: headlineSize,
        weight: .bold,
        color: cream,
        tracking: -headlineSize * 0.02,
        lineSpacing: headlineSize * 0.06
    )
    let headlineHeight = draw(headline, in: CGRect(
        x: margin, y: cursor - 400 * s,
        width: width - margin * 2, height: 400 * s
    ))
    cursor -= headlineHeight + 34 * s

    let subhead = attributed(
        panel.subhead,
        size: subheadSize,
        weight: .medium,
        color: cream.withAlphaComponent(0.72),
        lineSpacing: subheadSize * 0.22
    )
    let subheadHeight = draw(subhead, in: CGRect(
        x: margin * 1.15, y: cursor - 300 * s,
        width: width - margin * 2.3, height: 300 * s
    ))
    cursor -= subheadHeight + (isPad ? 96 : 84) * s

    // The device. Width is chosen so the frame fills the remaining space
    // without ever colliding with the subhead.
    let frameWidth = width * (isPad ? 0.74 : 0.80)
    let aspect = shot.size.height / shot.size.width
    let frameHeight = frameWidth * aspect
    let frameX = (width - frameWidth) / 2
    // Anchored to the bottom and allowed to run off the canvas: showing the top
    // two thirds of a screen reads as a device continuing past the edge, which
    // is stronger than shrinking the whole screen to fit.
    let frameY = cursor - frameHeight
    let frameRect = CGRect(x: frameX, y: frameY, width: frameWidth, height: frameHeight)

    let cornerRadius = frameWidth * (isPad ? 0.045 : 0.088)

    // Drop shadow.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -24 * s),
        blur: 70 * s,
        color: NSColor.black.withAlphaComponent(0.55).cgColor
    )
    let shadowPath = CGPath(
        roundedRect: frameRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    context.addPath(shadowPath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // Screenshot, clipped to the rounded frame.
    context.saveGState()
    context.addPath(shadowPath)
    context.clip()
    shot.draw(in: frameRect, from: .zero, operation: .sourceOver, fraction: 1)
    context.restoreGState()

    // A hairline bezel so the light UI does not bleed into the navy.
    context.saveGState()
    context.addPath(shadowPath)
    context.setStrokeColor(cream.withAlphaComponent(0.16).cgColor)
    context.setLineWidth(3 * s)
    context.strokePath()
    context.restoreGState()

    // Call to action, on the panels that carry one.
    if let cta = panel.cta {
        let text = attributed(
            cta,
            size: subheadSize * 0.86,
            weight: .semibold,
            color: navy,
            tracking: subheadSize * 0.01
        )
        let textSize = text.size()
        let padX = 52 * s, padY = 26 * s
        // Floated over the lower part of the device rather than tucked at the
        // very bottom, where it collided with the app's own tab bar and read as
        // part of the UI instead of as a badge on top of it.
        let pill = CGRect(
            x: (width - textSize.width) / 2 - padX,
            y: height * 0.085,
            width: textSize.width + padX * 2,
            height: textSize.height + padY * 2
        )
        let pillPath = CGPath(
            roundedRect: pill,
            cornerWidth: pill.height / 2,
            cornerHeight: pill.height / 2,
            transform: nil
        )
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -10 * s),
            blur: 40 * s,
            color: NSColor.black.withAlphaComponent(0.5).cgColor
        )
        context.addPath(pillPath)
        context.setFillColor(coral.cgColor)
        context.fillPath()
        context.restoreGState()

        text.draw(with: CGRect(
            x: pill.minX + padX,
            y: pill.minY + padY - textSize.height * 0.08,
            width: textSize.width,
            height: textSize.height
        ), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    guard let png = rep.representation(using: .png, properties: [:]) else { return }

    let slug = String(panel.source.dropFirst(3))
    let name = String(format: "%02d-%@.png", index + 1, slug)
    let url = outputDirectory.appendingPathComponent(name)
    try? png.write(to: url)
    print("  \(name)")
}

print("Composing \(device) (\(Int(width))x\(Int(height)))")
for (index, panel) in panels.enumerated() {
    compose(panel, index: index)
}
print("Done.")
