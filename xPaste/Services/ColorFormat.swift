import AppKit

/// Rendering a colour back to a literal.
///
/// The other half of `ColorParser`, which only ever read them. Kept apart from it so the parser
/// stays the single authority on what *counts* as a colour — this file has no opinion on that, it
/// only writes what it is handed.
enum ColorFormat: CaseIterable {
    case hex
    case rgb
    case hsl

    var title: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        }
    }

    /// The literal for `colour`, in this notation.
    ///
    /// Alpha is written only when the colour is not opaque: `#1e90ff` rather than `#1e90ffff`,
    /// because the six-digit form is what anyone pasting into CSS expects.
    func render(_ colour: NSColor) -> String {
        // Converted first because reading `.redComponent` off a colour in another space — `NSColor
        // .black` is Generic Gray — raises an uncatchable NSInvalidArgumentException. The same trap
        // `RichTextRenderer` documents.
        let c = colour.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent, a = c.alphaComponent
        // Must agree with `number`'s rounding below: an alpha that prints as "1" has to take the
        // opaque form too, or an rgba()/hsla() literal comes out with a trailing alpha of 1.
        let opaque = a >= 0.995

        switch self {
        case .hex:
            let base = String(format: "#%02x%02x%02x", channel(r), channel(g), channel(b))
            return opaque ? base : base + String(format: "%02x", channel(a))
        case .rgb:
            let base = "\(channel(r)), \(channel(g)), \(channel(b))"
            return opaque ? "rgb(\(base))" : "rgba(\(base), \(number(a)))"
        case .hsl:
            let (h, s, l) = hsl(r: r, g: g, b: b)
            let base = "\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
            return opaque ? "hsl(\(base))" : "hsla(\(base), \(number(a)))"
        }
    }

    private func channel(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// Trailing zeros dropped, so an alpha of a half reads `0.5` rather than `0.500000`.
    private func number(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }

    /// The inverse of `ColorParser.fromHSL`, kept here rather than there so the parser keeps its one
    /// direction.
    private func hsl(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }   // grey has no hue to report
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: CGFloat
        switch maxV {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h = (h / 6) * 360
        return (h, s, l)
    }
}
