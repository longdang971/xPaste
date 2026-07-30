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
    static func unbackedRanges(of text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.backgroundColor,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            guard let colour = (value as? NSColor)?.usingColorSpace(.deviceRGB),
                  colour.alphaComponent > 0.01 else {
                ranges.append(range)
                return
            }
        }
        return ranges
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

    static var cardPreviewSize: CGSize {
        CGSize(width: PanelLayout.cardBaseWidth,
               height: PanelLayout.cardBaseHeight
                   - PanelLayout.cardHeaderHeight
                   - PanelLayout.cardFooterHeight)
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
                            defaultFill: NSColor = .textBackgroundColor) async -> RichCardPreview {
        let parsed: ParsedRich?
        if item.richType == NSPasteboard.PasteboardType.rtf.rawValue {
            parsed = await Task.detached(priority: .userInitiated) { parse(item) }.value
        } else {
            // The HTML importer is WebKit-backed and main-thread only.
            parsed = parse(item)
        }
        guard let parsed else { return .plain(forLightAppearance: forLightAppearance) }

        let fill = resolveFill(runBackground: dominantBackground(of: parsed.text),
                               documentBackground: parsed.documentBackground)
        let effective = fill ?? defaultFill
        guard fill != nil || isLegible(parsed.text, on: effective) else {
            return .plain(forLightAppearance: forLightAppearance)
        }

        let body = parsed.text.length > cardCharLimit
            ? parsed.text.attributedSubstring(from: NSRange(location: 0, length: cardCharLimit))
            : parsed.text
        guard let image = rasterise(body, fill: effective, size: size) else {
            return .plain(forLightAppearance: forLightAppearance)
        }
        return RichCardPreview(image: image, fill: fill,
                               builtForLightAppearance: forLightAppearance)
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
        let fill = resolveFill(runBackground: dominantBackground(of: parsed.text),
                               documentBackground: parsed.documentBackground)
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
        text.draw(with: NSRect(x: cardPadding, y: cardPadding,
                               width: size.width - 2 * cardPadding,
                               height: size.height - 2 * cardPadding),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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

    init(image: NSImage?, fill: NSColor?, builtForLightAppearance: Bool = true) {
        self.image = image
        self.fill = image == nil ? nil : fill
        self.builtForLightAppearance = builtForLightAppearance
    }

    /// Whether this entry can still be shown under `lightAppearance`.
    ///
    /// Entries carrying a real run background do not actually depend on the appearance, but a
    /// flip is rare and rebuilding them too is far simpler than tracking which ones do.
    func isUsable(underLightAppearance lightAppearance: Bool) -> Bool {
        builtForLightAppearance == lightAppearance
    }

    static func plain(forLightAppearance light: Bool) -> RichCardPreview {
        RichCardPreview(image: nil, fill: nil, builtForLightAppearance: light)
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
