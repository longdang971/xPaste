#!/usr/bin/env swift
//
//  GenerateAppIcon.swift
//  Draws the xPaste app icon and writes every PNG the asset catalog asks for.
//
//  Run:  swift Tools/GenerateAppIcon.swift [output-directory]
//        (defaults to xPaste/Resources/Assets.xcassets/AppIcon.appiconset)
//
//  The design: a clipboard board with a card sliding out of it, the card
//  carrying the xPaste "x". Everything lives inside a narrow band of amber —
//  no surface is darker than the background — so the icon reads as one warm
//  material, with white doing all the contrast work.
//

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

/// Everything is authored and written in sRGB so the sampled values survive
/// the round trip byte for byte.
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: String) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return CGColor(colorSpace: sRGB, components: [
        CGFloat((v >> 16) & 0xFF) / 255,
        CGFloat((v >> 8) & 0xFF) / 255,
        CGFloat(v & 0xFF) / 255, 1,
    ])!
}

func black(_ alpha: CGFloat) -> CGColor {
    CGColor(colorSpace: sRGB, components: [0, 0, 0, alpha])!
}

func tinted(_ hex: String, _ alpha: CGFloat) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return CGColor(colorSpace: sRGB, components: [
        CGFloat((v >> 16) & 0xFF) / 255,
        CGFloat((v >> 8) & 0xFF) / 255,
        CGFloat(v & 0xFF) / 255, alpha,
    ])!
}

// MARK: - Palette

/// The amber field, sampled top-to-bottom off the reference. It stops changing
/// two thirds of the way down and stays flat to the bottom edge.
let fieldStops: [(CGFloat, String)] = [
    (0.00, "FFC47B"), (0.08, "FFC277"), (0.16, "FFBF6F"), (0.25, "FEBB66"),
    (0.33, "FCB85E"), (0.41, "FAB457"), (0.50, "F8B04F"), (0.58, "F6AC4B"),
    (0.66, "F4A946"), (1.00, "F5A946"),
]

let amber = color("F5A946")      // the flat lower two thirds
let boardWhite = color("FFF4E3") // warm white — the clipboard board
let cardWhite = color("FFFFFF")  // the card that slid out
let shadowTintHex = "7A4404"     // shadows stay inside the warm family

/// Below ~32px the board and the card are too close in value to survive
/// downsampling, so small renderings deepen the board just enough to keep the
/// card's edge readable. Apple's own icons make the same trade.
let boardWhiteSmall = color("FFE4BC")

// MARK: - Geometry
//
// The artwork is authored in a 200x200 space that maps onto the rounded
// square itself. macOS then wants that square inset in a larger canvas with
// room for a drop shadow: at 1024 the body is 824 wide, 100 in from each side,
// 90 from the top and 110 from the bottom.

let bodyRatio: CGFloat = 824.0 / 1024.0
let insetTopRatio: CGFloat = 90.0 / 1024.0
let cornerRatio: CGFloat = 185.4 / 824.0

/// How much of the drawing survives at a given rendering size.
///
/// At 16px the rounded square is only about 13 pixels across, which leaves the
/// clip under two pixels wide and the x barely one pixel thick — the full
/// artwork turns to mush. Small sizes therefore get their own layout rather
/// than the same one with tweaked numbers.
enum Detail {
    case full     // 64 and up: everything, as authored
    case reduced  // 32: no notch inside the clip, deeper board, fatter x
    case minimal  // 16: no clip, no shadows, one big card and a heavy x

    init(pixelSize: Int) {
        switch pixelSize {
        case ...16: self = .minimal
        case ...32: self = .reduced
        default: self = .full
        }
    }
}

struct Art {
    var boardFill: CGColor
    var strokeWidth: CGFloat
    var drawNotch: Bool
    var shadows: Bool
}

func art(for detail: Detail) -> Art {
    switch detail {
    case .full:    return Art(boardFill: boardWhite, strokeWidth: 13, drawNotch: true, shadows: true)
    case .reduced: return Art(boardFill: boardWhiteSmall, strokeWidth: 16, drawNotch: false, shadows: true)
    case .minimal: return Art(boardFill: boardWhiteSmall, strokeWidth: 26, drawNotch: false, shadows: false)
    }
}

// MARK: - Drawing

func drawIcon(size: Int) -> CGImage {
    let n = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // Flip to a y-down space so the authored coordinates read directly. Note
    // that Core Graphics transforms shadow offsets by the CTM too, so every
    // shadow below uses a negative dy to fall downwards on screen.
    ctx.translateBy(x: 0, y: n)
    ctx.scaleBy(x: 1, y: -1)

    let side = (n * bodyRatio).rounded()
    let originX = ((n - side) / 2).rounded()
    let originY = (n * insetTopRatio).rounded()
    let radius = side * cornerRatio
    let body = CGRect(x: originX, y: originY, width: side, height: side)
    let detail = Detail(pixelSize: size)
    let spec = art(for: detail)

    // Drop shadow under the whole icon, the way macOS icons carry one.
    if spec.shadows {
        ctx.saveGState()
        // Measured off the reference: the ground darkens ~3% beside and above
        // the icon and ~12% right under it. Anything heavier reads as a halo.
        ctx.setShadow(offset: CGSize(width: 0, height: -n * 0.009),
                      blur: n * 0.012,
                      color: black(0.16))
        ctx.setFillColor(black(1))
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Clip everything to the rounded square, then work in authored units.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    let u = side / 200.0                     // authored unit -> pixels
    ctx.translateBy(x: body.minX, y: body.minY)
    ctx.scaleBy(x: u, y: u)

    // The amber field.
    let colors = fieldStops.map { color($0.1) } as CFArray
    let locations = fieldStops.map { $0.0 }
    if let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: locations) {
        ctx.saveGState()
        ctx.addRect(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                               end: CGPoint(x: 0, y: 200), options: [])
        ctx.restoreGState()
    }

    ctx.translateBy(x: -4, y: 0)

    func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
               cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // Everything below is laid out per detail level: board, clip, card, x, and
    // the angle the card sits at.
    let board: CGPath
    let card: CGPath
    let pivot: CGPoint
    let angle: CGFloat
    let armStart: CGFloat, armEnd: CGFloat, armTop: CGFloat, armBottom: CGFloat

    switch detail {
    case .full, .reduced:
        board = rounded(36, 56, 100, 110, 16)
        card = rounded(90, 56, 82, 96, 14)
        pivot = CGPoint(x: 130, y: 104)
        angle = 9
        (armStart, armEnd, armTop, armBottom) = (114, 148, 87, 121)
    case .minimal:
        // One cream slab and one big card, both grown to fill the square, so a
        // 13-pixel icon still shows three distinct shapes and a legible x.
        board = rounded(26, 48, 92, 120, 14)
        card = rounded(80, 40, 100, 116, 16)
        pivot = CGPoint(x: 130, y: 98)
        angle = 7
        (armStart, armEnd, armTop, armBottom) = (104, 156, 72, 124)
    }

    // The board.
    ctx.saveGState()
    if spec.shadows {
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 7,
                      color: tinted(shadowTintHex, 0.30))
    }
    ctx.setFillColor(spec.boardFill)
    ctx.addPath(board)
    ctx.fillPath()
    ctx.restoreGState()

    // The clip straddling the board's top edge. It is under two pixels wide at
    // 16, where it only muddies the silhouette, so the minimal build drops it.
    if detail != .minimal {
        ctx.setFillColor(amber)
        ctx.addPath(rounded(46, 42, 60, 27, 12))
        ctx.fillPath()
        if spec.drawNotch {
            ctx.setFillColor(spec.boardFill)
            ctx.addPath(rounded(60, 49, 26, 12, 6))
            ctx.fillPath()
        }
    }

    // The card, tipped out of the board, and the x it carries.
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: angle * .pi / 180)
    ctx.translateBy(x: -pivot.x, y: -pivot.y)

    ctx.saveGState()
    if spec.shadows {
        ctx.setShadow(offset: CGSize(width: -2, height: -4), blur: 10,
                      color: tinted(shadowTintHex, 0.36))
    }
    ctx.setFillColor(cardWhite)
    ctx.addPath(card)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setStrokeColor(amber)
    ctx.setLineWidth(spec.strokeWidth)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: armStart, y: armTop)); ctx.addLine(to: CGPoint(x: armEnd, y: armBottom))
    ctx.move(to: CGPoint(x: armEnd, y: armTop)); ctx.addLine(to: CGPoint(x: armStart, y: armBottom))
    ctx.strokePath()

    ctx.restoreGState()   // card rotation
    ctx.restoreGState()   // rounded-square clip

    return ctx.makeImage()!
}

// MARK: - Output

let defaultOut = "xPaste/Resources/Assets.xcassets/AppIcon.appiconset"
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : defaultOut
let sizes = [16, 32, 64, 128, 256, 512, 1024]

for size in sizes {
    let image = drawIcon(size: size)
    let url = URL(fileURLWithPath: "\(outDir)/icon_\(size).png")
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("could not open \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("could not encode \(size)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(url.path)  \(size)x\(size)")
}

