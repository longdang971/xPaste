#!/usr/bin/env swift
//
//  GenerateMenuBarIcon.swift
//  Draws the monochrome status-bar glyph: the app icon's two cards, without
//  the rounded square around them.
//
//  Run:  swift Tools/GenerateMenuBarIcon.swift [variant] [output-directory]
//        variant: solid (default) | clipped | outline
//
//  This is a template image, so only the alpha channel survives — macOS paints
//  it black or white to suit the menu bar. Which means the two cards cannot be
//  told apart by colour: the front card is separated from the board by a
//  cleared gap, and the x is knocked out of the front card rather than drawn
//  on it, the same relationship the full-colour icon has.
//

import CoreGraphics
import ImageIO
import Foundation

enum Variant: String {
    case solid    // two filled cards, x knocked out of the front one
    case clipped  // the same, plus the clipboard's clip on the board
    case outline  // both cards as outlines, x drawn solid inside
}

let variant = Variant(rawValue: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "solid") ?? .solid
let defaultOut = "xPaste/Resources/Assets.xcassets/MenuBarIcon.imageset"
let outDir = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : defaultOut

// Authored in a 100x100 space, then scaled to whatever the run needs.
// The front card takes nearly the whole square and the board is reduced to a
// sliver behind it. At 18 points the x is the only part anyone actually reads,
// so it gets the room; the board just has to say "there are more of these".
let boardRect = CGRect(x: 2, y: 18, width: 44, height: 76)
let boardRadius: CGFloat = 11
let cardRect = CGRect(x: 26, y: 6, width: 68, height: 84)
let cardRadius: CGFloat = 13
let cardPivot = CGPoint(x: 60, y: 48)
let cardAngle: CGFloat = 7

/// The drawing is authored edge to edge, then pulled in so the glyph does not
/// crowd its neighbours in the menu bar.
let contentScale: CGFloat = 0.94

/// The transparent channel that separates the front card from the board.
let gap: CGFloat = 6
/// Stroke weight for the outline variant and for the x.
let outlineWeight: CGFloat = 8
let crossWeight: CGFloat = 14

func roundedPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

var cardTransform: CGAffineTransform {
    CGAffineTransform(translationX: cardPivot.x, y: cardPivot.y)
        .rotated(by: cardAngle * .pi / 180)
        .translatedBy(x: -cardPivot.x, y: -cardPivot.y)
}

func transformed(_ path: CGPath) -> CGPath {
    var t = cardTransform
    return path.copy(using: &t)!
}

/// The x, in the front card's own (unrotated) coordinates.
func crossPath() -> CGPath {
    let c = CGPoint(x: cardRect.midX, y: cardRect.midY)
    let arm: CGFloat = 18
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x - arm, y: c.y - arm))
    p.addLine(to: CGPoint(x: c.x + arm, y: c.y + arm))
    p.move(to: CGPoint(x: c.x + arm, y: c.y - arm))
    p.addLine(to: CGPoint(x: c.x - arm, y: c.y + arm))
    return p.copy(strokingWithWidth: crossWeight, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

func draw(size: Int) -> CGImage {
    let n = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Flip to y-down and scale the 100-unit authoring space onto the canvas.
    ctx.translateBy(x: 0, y: n)
    ctx.scaleBy(x: 1, y: -1)
    ctx.scaleBy(x: n / 100, y: n / 100)
    ctx.translateBy(x: 50, y: 50)
    ctx.scaleBy(x: contentScale, y: contentScale)
    ctx.translateBy(x: -50, y: -50)

    let black = CGColor(gray: 0, alpha: 1)
    let board = roundedPath(boardRect, boardRadius)
    let card = transformed(roundedPath(cardRect, cardRadius))
    let cross = transformed(crossPath())

    switch variant {
    case .solid, .clipped:
        ctx.setFillColor(black)
        ctx.addPath(board)
        ctx.fillPath()

        if variant == .clipped {
            // The clip straddling the board's top edge, as on the app icon.
            ctx.addPath(roundedPath(CGRect(x: 12, y: 12, width: 27, height: 18), 8))
            ctx.fillPath()
        }

        // Clear the front card plus a ring around it, so the two cards read as
        // two objects instead of one blob once the system flattens the colour.
        ctx.setBlendMode(.clear)
        ctx.addPath(card)
        ctx.fillPath()
        ctx.addPath(card)
        ctx.setLineWidth(gap * 2)
        ctx.strokePath()

        ctx.setBlendMode(.normal)
        ctx.setFillColor(black)
        ctx.addPath(card)
        ctx.fillPath()

        // Knock the x out of the card.
        ctx.setBlendMode(.clear)
        ctx.addPath(cross)
        ctx.fillPath()
        ctx.setBlendMode(.normal)

    case .outline:
        ctx.setStrokeColor(black)
        ctx.setLineWidth(outlineWeight)

        // Clear a gap through the board where the front card crosses it, then
        // outline both.
        ctx.addPath(board)
        ctx.strokePath()

        ctx.setBlendMode(.clear)
        ctx.addPath(card)
        ctx.fillPath()
        ctx.addPath(card)
        ctx.setLineWidth(gap * 2)
        ctx.strokePath()
        ctx.setBlendMode(.normal)

        ctx.setStrokeColor(black)
        ctx.setLineWidth(outlineWeight)
        ctx.addPath(card)
        ctx.strokePath()

        ctx.setFillColor(black)
        ctx.addPath(cross)
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

for (size, name) in [(18, "menubar_x_18"), (36, "menubar_x_36")] {
    let url = URL(fileURLWithPath: "\(outDir)/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, draw(size: size), nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("could not write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(url.path)  \(size)x\(size)  [\(variant.rawValue)]")
}
