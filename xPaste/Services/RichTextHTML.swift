import AppKit

/// The markup raw mode shows, and the parse that takes it back.
///
/// Apart from the editor because this is the half that can silently lose a highlight, and it is
/// only testable at all if it never needs a text view on screen.
///
/// HTML rather than RTF even though RTF is what an item stores. Raw mode exists to be typed in, and
/// `{\rtf1\ansi\ansicpg1252\cocoartf2822{\fonttbl\f0\fswiss\fcharset0 Helvetica;}` is not something
/// a person types.
enum RichTextHTML {

    /// Both directions are bounded by the same cap `RichTextRenderer` puts on captured HTML. The
    /// importer is WebKit-backed and main-thread only, so a half-megabyte item has to be refused
    /// entry to raw mode rather than allowed to freeze the panel.
    static let byteCap = RichTextRenderer.htmlByteCap

    /// The size the prelude gives anything the markup does not style, so a run at exactly this size
    /// needs no `font-size` of its own.
    static let defaultSize: CGFloat = 13

    // MARK: - Writing

    /// The markup for an attributed string, or nil when it would exceed `byteCap`.
    ///
    /// One `<p>` per line and no `<br>` at all. That is not a style choice: the importer gives every
    /// `<p>` a trailing newline, so this is the shape `attributed(from:)` can reverse exactly.
    static func html(from attributed: NSAttributedString) -> String? {
        let ns = attributed.string as NSString
        var paragraphs: [String] = []
        var lineStart = 0
        while lineStart <= ns.length {
            let rest = NSRange(location: lineStart, length: ns.length - lineStart)
            let newline = ns.range(of: "\n", options: [], range: rest)
            let lineEnd = newline.location == NSNotFound ? ns.length : newline.location
            paragraphs.append(
                runs(of: attributed, in: NSRange(location: lineStart, length: lineEnd - lineStart)))
            if newline.location == NSNotFound { break }
            lineStart = newline.location + newline.length
        }
        let html = paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n")
        guard html.utf8.count <= byteCap else { return nil }
        return html
    }

    private static func runs(of attributed: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        let ns = attributed.string as NSString
        var out = ""
        attributed.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
            out += markup(for: attrs, text: ns.substring(with: runRange))
        }
        return out
    }

    /// One run of uniform attributes.
    ///
    /// A face is named by its **PostScript name** rather than a family plus `font-weight`. Measured
    /// against the importer, `'Helvetica Neue'` at `font-weight:500` comes back as
    /// HelveticaNeue-Medium and at 600 as Bold, while `font-family:HelveticaNeue-Light` comes back
    /// as exactly itself and `font-family:Menlo-BoldItalic` brings both traits with it.
    ///
    /// The system font is the exception and is written as `<b>`/`<i>` with no family at all: its
    /// family name is the private `.AppleSystemUIFont`. Left unnamed it picks up the prelude's
    /// `-apple-system` at 13px, which is the editor's own default — so the ordinary case stays
    /// clean, which is the whole point of showing this to a person.
    private static func markup(for attrs: [NSAttributedString.Key: Any], text: String) -> String {
        var inner = escape(text)
        let font = attrs[.font] as? NSFont
        let link = attrs[.link] as? URL ?? (attrs[.link] as? String).flatMap(URL.init(string:))
        let system = font.map(isSystemFace) ?? true

        if system, let font {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) { inner = "<b>\(inner)</b>" }
            if traits.contains(.italicFontMask) { inner = "<i>\(inner)</i>" }
        }
        // A link's blue and its underline are put there by the importer, not by the source. Writing
        // them back out would bake the importer's own styling a little deeper on every round trip.
        if link == nil, (attrs[.underlineStyle] as? Int ?? 0) != 0 { inner = "<u>\(inner)</u>" }
        if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { inner = "<s>\(inner)</s>" }

        var styles: [String] = []
        if let font, !system {
            styles.append("font-family:\(font.fontName)")
            styles.append("font-size:\(number(font.pointSize))px")
        } else if let font, font.pointSize != defaultSize {
            styles.append("font-size:\(number(font.pointSize))px")
        }
        if link == nil, let fg = attrs[.foregroundColor] as? NSColor, fg != .labelColor {
            styles.append("color:\(hex(fg))")
        }
        if let bg = attrs[.backgroundColor] as? NSColor, bg.alphaComponent > 0.01 {
            styles.append("background-color:\(hex(bg))")
        }
        if !styles.isEmpty {
            inner = "<span style=\"\(styles.joined(separator: ";"))\">\(inner)</span>"
        }
        if let link { inner = "<a href=\"\(escape(link.absoluteString))\">\(inner)</a>" }
        return inner
    }

    /// Whether this is the system face, in any of its weights — they all share the one family name.
    static func isSystemFace(_ font: NSFont) -> Bool {
        font.familyName == NSFont.systemFont(ofSize: defaultSize).familyName
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private static func hex(_ colour: NSColor) -> String {
        // `usingColorSpace` first because reading `.redComponent` off a Generic Gray colour raises
        // an uncatchable NSInvalidArgumentException — the same trap `RichTextRenderer` documents.
        guard let rgb = colour.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
