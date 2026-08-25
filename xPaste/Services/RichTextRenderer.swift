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

/// A parse result, nil included, so the cache can remember that an item has no rich text.
final class ParsedRichBox {
    let value: ParsedRich?
    init(_ value: ParsedRich?) { self.value = value }
}

/// Turns a clipboard item's captured RTF/HTML into something drawable.
///
/// The card keeps its ordinary surface and every run paints its own background behind its own
/// glyphs — a terminal transcript comes back as dark boxes hugging each line on an otherwise white
/// card, a highlighted sentence as a yellow box around exactly that sentence.
///
/// This was checked against Paste by copying a mixed RTF document out of TextEdit (bold heading,
/// yellow highlight, coloured text, two terminal lines) and photographing the card it built: white
/// body, white footer, one box per backed run. An earlier reading of the same panel concluded that
/// the majority run background floods the whole card, and that is what this file used to do; the
/// TextEdit sample shows it does not.
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

    /// A stylesheet glued in front of every HTML fragment before it reaches the importer.
    ///
    /// A browser puts the *markup* of the selection on the pasteboard, not the page's stylesheet,
    /// so a fragment copied from an ordinary web page usually names no font at all. Left to itself
    /// the WebKit importer then applies its own default — Times-Roman 12 — and a card drawn from a
    /// sans-serif page comes back in a serif the user never saw on screen.
    ///
    /// The `html` selector is the weakest one that still outranks the importer's default, so
    /// anything the fragment *does* specify (an inline `font-family`, a `<pre>`, a page that
    /// shipped its own `<style>`) keeps winning. Note this only restyles what the source left
    /// unstyled; it is not a way to impose a house font on rich text.
    ///
    /// It is prepended to the raw bytes rather than the decoded string on purpose: the fragment
    /// carries its own `<meta charset>` and may not be UTF-8, and decoding it here to concatenate
    /// would be guessing at an encoding the importer already knows how to detect. ASCII-only, so
    /// it cannot corrupt the bytes that follow under any of them.
    ///
    /// Shared with `RichTextHTML`, which faces the same importer from the other direction: markup
    /// typed by hand names no font either, and would land in Times-Roman for the same reason.
    static let htmlDefaultFontPrelude = Data(
        "<style>html{font-family:-apple-system,'Helvetica Neue',Helvetica,sans-serif;font-size:13px}</style>".utf8)

    // MARK: - Parsing

    /// Parses, remembering the answer — including "this one has none".
    ///
    /// The parse is the expensive half and it does not depend on the search box, so re-running it
    /// per keystroke would be pure waste. For HTML it is worse than waste: `NSAttributedString`'s
    /// HTML importer is WebKit-backed and main-thread only, so an uncached parse puts a WebKit
    /// document build on the panel's main thread for every character typed.
    ///
    /// Negative results are cached too, in a box, because `NSCache` cannot hold nil — otherwise an
    /// item whose `richData` does not parse would be re-attempted on every keystroke, which is the
    /// exact case this cache exists to prevent.
    static func cachedParse(_ item: ClipboardItem) -> ParsedRich? {
        if let boxed = parseCache.object(forKey: item.id as NSUUID) { return boxed.value }
        let parsed = parse(item)
        parseCache.setObject(ParsedRichBox(parsed), forKey: item.id as NSUUID)
        return parsed
    }

    private static let parseCache: NSCache<NSUUID, ParsedRichBox> = {
        let c = NSCache<NSUUID, ParsedRichBox>(); c.countLimit = 120; return c
    }()

    /// Drops what was parsed for an item whose content has been edited underneath it.
    ///
    /// The cache is keyed by id, and an id survives an edit — so without this the editor's changes
    /// are written to disk and the card goes on drawing the string that was parsed before them.
    static func forget(_ id: UUID) {
        parseCache.removeObject(forKey: id as NSUUID)
    }

    static func parse(_ item: ClipboardItem) -> ParsedRich? {
        guard item.type == .text || item.type == .url,
              let rawType = item.richType,
              let data = ClipboardStore.shared.richBytes(for: item), !data.isEmpty
        else { return nil }

        var docAttrs: NSDictionary?
        let parsed: NSAttributedString?
        switch rawType {
        case NSPasteboard.PasteboardType.rtf.rawValue:
            guard data.count <= rtfByteCap else { return nil }
            parsed = NSAttributedString(rtf: data, documentAttributes: &docAttrs)
        case NSPasteboard.PasteboardType.html.rawValue:
            guard data.count <= htmlByteCap else { return nil }
            parsed = NSAttributedString(html: htmlDefaultFontPrelude + data,
                                        documentAttributes: &docAttrs)
        default:
            return nil
        }

        guard let parsed, parsed.length > 0 else { return nil }
        let background = (docAttrs as? [NSAttributedString.DocumentAttributeKey: Any])?[.backgroundColor] as? NSColor
        return ParsedRich(text: parsed, documentBackground: background)
    }

    // MARK: - Choosing the fill

    /// The colour the card is painted with, or nil to keep the ordinary card surface.
    ///
    /// Only a *document* background counts. Run backgrounds are deliberately not consulted: they
    /// are drawn behind their own glyphs by the text system, and promoting the most popular one to
    /// the whole card is what made a terminal transcript arrive as a solid black tile.
    ///
    /// A document background is a different claim — the source saying "the page this came from was
    /// this colour" — and it is the only thing standing between light unbacked text and an
    /// invisible card, so it is still honoured.
    static func resolveFill(documentBackground: NSColor?) -> NSColor? {
        documentBackground
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
    ///
    /// `ranges` narrows the tally to part of the string; `isLegible` uses it to ask only about the
    /// runs that are actually painted onto the fill.
    static func dominantForeground(of text: NSAttributedString,
                                   in ranges: [NSRange]? = nil) -> NSColor {
        var tally: [String: (colour: NSColor, characters: Int)] = [:]
        for scope in ranges ?? [NSRange(location: 0, length: text.length)] {
            text.enumerateAttribute(.foregroundColor,
                                    in: scope,
                                    options: []) { value, range, _ in
                // The trailing fallback must already be in an RGB colourspace: `NSColor.black` is
                // Generic Gray, and `colourKey` below reads `.redComponent`, which raises an
                // uncatchable NSInvalidArgumentException on a grey colour.
                let colour = ((value as? NSColor) ?? .black).usingColorSpace(.deviceRGB)
                    ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                let key = colourKey(colour)
                tally[key] = (colour, (tally[key]?.characters ?? 0) + range.length)
            }
        }
        // Same reason for the sRGB literal: this colour is handed to callers that may read its
        // components directly.
        return tally.values.max(by: { $0.characters < $1.characters })?.colour
            ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    }

    /// The stretches of text that are painted straight onto the card's fill, because they carry no
    /// background of their own.
    ///
    /// Whitespace is left out. It draws nothing either way, and counting it decided the opposite of
    /// what the eye sees: a terminal transcript backs every glyph but leaves its indentation and
    /// line breaks unbacked, so tallying those spaces put "light text on a white card" in front of
    /// the legibility guard and dropped the item to plain text — throwing away the very boxes that
    /// made it readable.
    static func unbackedRanges(of text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        let string = text.string as NSString
        text.enumerateAttribute(.backgroundColor,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            if let colour = (value as? NSColor)?.usingColorSpace(.deviceRGB),
               colour.alphaComponent > 0.01 { return }
            ranges.append(contentsOf: glyphBearingRanges(within: range, of: string))
        }
        return ranges
    }

    /// Splits a range into the stretches that contain something visible, dropping the whitespace
    /// between them.
    private static func glyphBearingRanges(within range: NSRange, of string: NSString) -> [NSRange] {
        let blank = CharacterSet.whitespacesAndNewlines
        var out: [NSRange] = []
        var cursor = range
        while cursor.length > 0 {
            let start = string.rangeOfCharacter(from: blank.inverted, options: [], range: cursor)
            guard start.location != NSNotFound else { break }
            let tail = NSRange(location: start.location,
                               length: NSMaxRange(cursor) - start.location)
            let nextBlank = string.rangeOfCharacter(from: blank, options: [], range: tail)
            let end = nextBlank.location == NSNotFound ? NSMaxRange(cursor) : nextBlank.location
            out.append(NSRange(location: start.location, length: end - start.location))
            cursor = NSRange(location: end, length: NSMaxRange(range) - end)
        }
        return out
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
    ///
    /// Only the runs with no background of their own are weighed, because only they land on the
    /// fill. Tallying the rest confuses a highlight with a disappearing act: a black-on-yellow run
    /// dragged the whole item to plain text on a dark card, discarding the very highlight that
    /// made it legible in the first place.
    static func isLegible(_ text: NSAttributedString, on fill: NSColor) -> Bool {
        let exposed = unbackedRanges(of: text)
        // Every run brings its own background, so the fill is never behind any glyph.
        guard !exposed.isEmpty else { return true }
        return contrastRatio(dominantForeground(of: text, in: exposed), fill) >= contrastFloor
    }

    // MARK: - Card previews

    /// Inset matching the plain `textPreview`'s padding, so switching between the two does not
    /// shift the text.
    static let cardPadding: CGFloat = 12

    /// Everything below the header, footer strip included.
    ///
    /// The text is laid out *through* the footer rather than stopping above it, so a long item
    /// keeps flowing and fades out behind the character count instead of ending on a hard edge a
    /// line early. The card overlays the footer on top of these pixels and fades them out; see
    /// `ClipboardItemCard.contentFlowsUnderFooter`.
    static var cardPreviewSize: CGSize {
        CGSize(width: PanelLayout.cardBaseWidth,
               height: PanelLayout.cardBaseHeight - PanelLayout.cardHeaderHeight)
    }

    /// The `NSColor.textBackgroundColor` of one specific appearance, resolved to a static colour.
    ///
    /// A card's bitmap is baked once and cached, so it cannot be painted with a dynamic colour:
    /// the pixels would keep the appearance that happened to be current when the bitmap was
    /// drawn. Resolving here means the caller decides which appearance it is drawing for, and
    /// `RichCardPreview` can record that decision.
    static func defaultFill(forLightAppearance light: Bool) -> NSColor {
        guard let appearance = NSAppearance(named: light ? .aqua : .darkAqua) else {
            return NSColor.textBackgroundColor
        }
        var resolved = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? resolved
        }
        return resolved
    }

    /// Always returns a decision, never nil — the caller caches either outcome.
    ///
    /// `forLightAppearance` is recorded on the result so a cached entry built under the other
    /// appearance can be discarded rather than redrawn from stale pixels.
    ///
    /// `defaultFill` is injectable because `NSColor.textBackgroundColor` resolves against the
    /// current appearance: white text with no background of its own is illegible in light mode
    /// but perfectly readable in dark. The app passes the fill of the appearance actually on
    /// screen (see `defaultFill(forLightAppearance:)`); tests pass a fixed one so their result
    /// does not depend on the machine's appearance.
    @MainActor
    static func cardPreview(for item: ClipboardItem,
                            size: CGSize,
                            forLightAppearance: Bool = true,
                            defaultFill: NSColor = .textBackgroundColor,
                            highlightTerm: String = "",
                            revision: Int = 0) async -> RichCardPreview {
        let parsed: ParsedRich?
        if parseCache.object(forKey: item.id as NSUUID) != nil {
            // Already parsed — a re-bake for a changed search term, so there is nothing to hop
            // threads for. This is the path every keystroke after the first one takes.
            parsed = cachedParse(item)
        } else if item.richType == NSPasteboard.PasteboardType.rtf.rawValue {
            parsed = await Task.detached(priority: .userInitiated) { cachedParse(item) }.value
        } else {
            // The HTML importer is WebKit-backed and main-thread only.
            parsed = cachedParse(item)
        }
        guard let parsed else {
            return .plain(forLightAppearance: forLightAppearance, term: highlightTerm,
                          revision: revision)
        }

        let fill = resolveFill(documentBackground: parsed.documentBackground)
        let effective = fill ?? defaultFill
        guard fill != nil || isLegible(parsed.text, on: effective) else {
            return .plain(forLightAppearance: forLightAppearance, term: highlightTerm,
                          revision: revision)
        }

        let truncated = parsed.text.length > cardCharLimit
            ? parsed.text.attributedSubstring(from: NSRange(location: 0, length: cardCharLimit))
            : parsed.text
        // Marked after truncating, so the work is bounded by what the card can show rather than by
        // the length of the thing that was copied.
        let body = highlightTerm.isEmpty
            ? truncated
            : SearchHighlight.marked(truncated, term: highlightTerm,
                                     forLightAppearance: forLightAppearance)
        guard let image = rasterise(body, fill: effective, size: size) else {
            return .plain(forLightAppearance: forLightAppearance, term: highlightTerm,
                          revision: revision)
        }
        return RichCardPreview(image: image, fill: fill,
                               builtForLightAppearance: forLightAppearance,
                               builtForTerm: highlightTerm,
                               builtForRevision: revision)
    }

    /// The popover's counterpart to `cardPreview`: the whole string, untruncated, because a
    /// popover exists one at a time and is where the user goes to read the thing.
    ///
    /// Synchronous and main-actor: the parse happens once from the popover's `.task`, never from
    /// its `body`.
    @MainActor
    static func fullPreview(for item: ClipboardItem,
                            defaultFill: NSColor = .textBackgroundColor) -> RichFullPreview? {
        guard let parsed = parse(item) else { return nil }
        let fill = resolveFill(documentBackground: parsed.documentBackground)
        guard fill != nil || isLegible(parsed.text, on: defaultFill) else { return nil }
        return RichFullPreview(text: parsed.text, fill: fill)
    }

    /// Lays the text out **once** into a bitmap.
    ///
    /// `lockFocusFlipped(true)` gives retina backing from the display and flipped coordinates, so
    /// the text flows downward from the top of the rect. A drawing-handler `NSImage` would re-run
    /// TextKit on every draw, which is the entire cost this is meant to avoid.
    @MainActor
    private static func rasterise(_ text: NSAttributedString,
                                  fill: NSColor,
                                  size: CGSize) -> NSImage? {
        guard size.width > 2 * cardPadding, size.height > 2 * cardPadding else { return nil }
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        fill.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        // No `.truncatesLastVisibleLine`: the card fades its own bottom out, and an ellipsis
        // hanging in the middle of that fade says "cut off here" where the fade already says
        // "there is more". `cardCharLimit` is what bounds the layout work, not this option.
        text.draw(with: NSRect(x: cardPadding, y: cardPadding,
                               width: size.width - 2 * cardPadding,
                               height: size.height - 2 * cardPadding),
                  options: [.usesLineFragmentOrigin])
        image.unlockFocus()
        return image
    }
}

/// A card's rich preview, or the decision not to draw one.
///
/// `image == nil` means "draw plain text" — a negative result worth caching, so an item that
/// resolved to plain is never parsed again when it scrolls back into view.
final class RichCardPreview {
    let image: NSImage?
    /// nil means "use `NSColor.textBackgroundColor`". Always nil when `image` is nil: a fill
    /// without an image would tint a footer whose preview is plain text.
    let fill: NSColor?
    /// The appearance this entry was built for.
    ///
    /// Both halves of the entry depend on it: an item with no run background is painted with the
    /// *resolved* `textBackgroundColor`, so its bitmap is a white rectangle in light mode and a
    /// near-black one in dark, and the legibility verdict that decided whether to draw at all was
    /// taken against that same fill. A cached entry recorded for the other appearance is
    /// therefore stale — the reader treats it as a miss and rebuilds.
    let builtForLightAppearance: Bool
    /// The search term baked into this bitmap, "" for none.
    ///
    /// The mark is drawn into the pixels, so an entry built for one term cannot be shown for
    /// another — the reader treats a mismatch as a miss, exactly as it does for the appearance.
    let builtForTerm: String
    /// Which version of the item's content these pixels are of.
    ///
    /// An edit does not change the item's id, so an entry still keyed to it is no longer of it.
    /// Treated as a miss for the same reason as the two above.
    let builtForRevision: Int

    init(image: NSImage?, fill: NSColor?, builtForLightAppearance: Bool = true,
         builtForTerm: String = "", builtForRevision: Int = 0) {
        self.image = image
        self.fill = image == nil ? nil : fill
        self.builtForLightAppearance = builtForLightAppearance
        self.builtForTerm = builtForTerm
        self.builtForRevision = builtForRevision
    }

    /// Whether this entry can still be shown under `lightAppearance` for `term` at `revision`.
    ///
    /// Entries carrying a real run background do not actually depend on the appearance, but a
    /// flip is rare and rebuilding them too is far simpler than tracking which ones do.
    func isUsable(underLightAppearance lightAppearance: Bool, term: String = "",
                  revision: Int = 0) -> Bool {
        builtForLightAppearance == lightAppearance
            && builtForTerm == term
            && builtForRevision == revision
    }

    static func plain(forLightAppearance light: Bool, term: String = "",
                      revision: Int = 0) -> RichCardPreview {
        RichCardPreview(image: nil, fill: nil, builtForLightAppearance: light,
                        builtForTerm: term, builtForRevision: revision)
    }
}

/// The full styled string for the preview popover.
final class RichFullPreview {
    let text: NSAttributedString
    let fill: NSColor?

    init(text: NSAttributedString, fill: NSColor?) {
        self.text = text
        self.fill = fill
    }
}
