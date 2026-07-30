import AppKit

/// A parsed `richData`.
///
/// A class rather than a tuple so it can cross a `Task.detached` boundary: `NSAttributedString`
/// is not `Sendable`, and RTF parsing is deliberately done off the main thread.
final class ParsedRich: @unchecked Sendable {
    let text: NSAttributedString
    /// The document-level background (an RTF `\viewbkcol`, an HTML `bgcolor`), if the source
    /// supplied one. Only a fallback — see `resolveFill`.
    let documentBackground: NSColor?

    init(text: NSAttributedString, documentBackground: NSColor?) {
        self.text = text
        self.documentBackground = documentBackground
    }
}

/// Turns a clipboard item's captured RTF/HTML into something drawable.
///
/// The rules here were read off Paste's own panel: three items were copied, photographed, and the
/// arithmetic reverse-engineered. The one that matters is `dominantBackground` — Paste fills a
/// whole card from the *run* backgrounds of the text, not from any document attribute, which is
/// why a terminal transcript fills a card black even though its RTF sets no document background.
enum RichTextRenderer {
    /// RTF parsing is off the main thread, so this cap only bounds memory and work, not latency.
    static let rtfByteCap = 4_000_000
    /// Far lower, because `NSAttributedString(html:)` is a WebKit importer that must run on the
    /// main thread — its cost lands directly on the panel.
    static let htmlByteCap = 262_144
    /// Enough to overfill the card several times at any plausible font size.
    static let cardCharLimit = 1500
    /// Below this contrast ratio the text would be near-invisible, so we draw plain text instead.
    static let contrastFloor: CGFloat = 1.5

    // MARK: - Parsing

    static func parse(_ item: ClipboardItem) -> ParsedRich? {
        guard item.type == .text || item.type == .url,
              let data = item.richData, !data.isEmpty,
              let rawType = item.richType
        else { return nil }

        var docAttrs: NSDictionary?
        let parsed: NSAttributedString?
        switch rawType {
        case NSPasteboard.PasteboardType.rtf.rawValue:
            guard data.count <= rtfByteCap else { return nil }
            parsed = NSAttributedString(rtf: data, documentAttributes: &docAttrs)
        case NSPasteboard.PasteboardType.html.rawValue:
            guard data.count <= htmlByteCap else { return nil }
            parsed = NSAttributedString(html: data, documentAttributes: &docAttrs)
        default:
            return nil
        }

        guard let parsed, parsed.length > 0 else { return nil }
        let background = (docAttrs as? [NSAttributedString.DocumentAttributeKey: Any])?[.backgroundColor] as? NSColor
        return ParsedRich(text: parsed, documentBackground: background)
    }

    // MARK: - Choosing the fill

    /// The run background covering the most characters, or nil when "no background" covers the
    /// most. Measured against Paste: 49 black of 84 characters wins the card even though 21 are
    /// yellow and 14 carry no background at all.
    static func dominantBackground(of text: NSAttributedString) -> NSColor? {
        var tally: [String: (colour: NSColor, characters: Int)] = [:]
        var unbacked = 0

        text.enumerateAttribute(.backgroundColor,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            guard let colour = (value as? NSColor)?.usingColorSpace(.deviceRGB),
                  colour.alphaComponent > 0.01 else {
                unbacked += range.length
                return
            }
            let key = colourKey(colour)
            tally[key] = (colour, (tally[key]?.characters ?? 0) + range.length)
        }

        guard let winner = tally.values.max(by: { $0.characters < $1.characters }),
              winner.characters > unbacked
        else { return nil }
        return winner.colour
    }

    /// Run backgrounds win; a document background is only consulted when no run has one.
    static func resolveFill(runBackground: NSColor?, documentBackground: NSColor?) -> NSColor? {
        runBackground ?? documentBackground
    }

    /// Two runs whose colours differ only by colour-space round-tripping must tally as one.
    private static func colourKey(_ colour: NSColor) -> String {
        String(format: "%.3f-%.3f-%.3f-%.3f",
               colour.redComponent, colour.greenComponent,
               colour.blueComponent, colour.alphaComponent)
    }

    // MARK: - Legibility

    /// The foreground colour covering the most characters. Text with no colour attribute draws
    /// black, so that is the default.
    static func dominantForeground(of text: NSAttributedString) -> NSColor {
        var tally: [String: (colour: NSColor, characters: Int)] = [:]
        text.enumerateAttribute(.foregroundColor,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            let colour = ((value as? NSColor) ?? .black).usingColorSpace(.deviceRGB) ?? .black
            let key = colourKey(colour)
            tally[key] = (colour, (tally[key]?.characters ?? 0) + range.length)
        }
        return tally.values.max(by: { $0.characters < $1.characters })?.colour ?? .black
    }

    /// WCAG relative-luminance contrast ratio, 1:1 to 21:1.
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func relativeLuminance(_ colour: NSColor) -> CGFloat {
        guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent)
             + 0.7152 * linear(c.greenComponent)
             + 0.0722 * linear(c.blueComponent)
    }

    /// Guards against a blank card: a source that hands over light text carrying no background
    /// anywhere would otherwise rasterise to nothing at all.
    static func isLegible(_ text: NSAttributedString, on fill: NSColor) -> Bool {
        contrastRatio(dominantForeground(of: text), fill) >= contrastFloor
    }
}
