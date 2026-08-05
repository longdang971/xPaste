import AppKit

/// Where the search box's text appears inside a card's text, and what colour to wash it.
///
/// Kept apart from the views and free of SwiftUI so the rules that can silently go wrong — losing a
/// character, failing to terminate, miscounting a position — are unit-testable on their own.
///
/// Two card paths consume this and they must agree: plain `Text` builds an `AttributedString` from
/// `split`, while a formatted card's baked bitmap marks an `NSAttributedString` from `nsRanges`.
/// Both take their colour from `fill`, so the same search cannot paint two different yellows on
/// two cards sitting side by side.
enum SearchHighlight {

    /// Every place `term` occurs in `text`.
    ///
    /// Matched with `.caseInsensitive` against the current locale, which is exactly how
    /// `SearchQuery` decided the item belonged in the results. Matching any other way would put
    /// cards on screen with nothing painted on them, or paint text the search never matched.
    static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        guard !term.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let hit = text.range(of: term, options: .caseInsensitive,
                                   range: cursor..<text.endIndex, locale: .current) {
            // A locale-sensitive search can report an empty range; stopping on one by hand is what
            // keeps this loop from spinning forever on a single position.
            guard !hit.isEmpty else { break }
            found.append(hit)
            cursor = hit.upperBound
        }
        return found
    }

    /// The same places as UTF-16 ranges, for marking an `NSAttributedString`.
    ///
    /// `NSAttributedString` counts UTF-16 units, not characters. Anything outside the BMP — an
    /// emoji, most obviously — makes the two diverge, and an offset that is off by one paints the
    /// wash over the wrong glyphs instead of failing loudly.
    static func nsRanges(of term: String, in text: String) -> [NSRange] {
        ranges(of: term, in: text).map { NSRange($0, in: text) }
    }

    /// `text` cut into consecutive runs, each flagged as a hit or not.
    ///
    /// Concatenating the runs always reproduces `text`.
    static func split(_ text: String, term: String) -> [(text: String, isMatch: Bool)] {
        let hits = ranges(of: term, in: text)
        guard !hits.isEmpty else { return [(text, false)] }

        var runs: [(text: String, isMatch: Bool)] = []
        var cursor = text.startIndex
        for hit in hits {
            if hit.lowerBound > cursor {
                runs.append((String(text[cursor..<hit.lowerBound]), false))
            }
            // The text's own characters, not the term's: the search is case-insensitive, so the
            // two can differ, and the card must keep showing what was copied.
            runs.append((String(text[hit]), true))
            cursor = hit.upperBound
        }
        if cursor < text.endIndex {
            runs.append((String(text[cursor...]), false))
        }
        return runs
    }

    /// The wash behind a hit.
    ///
    /// Dark mode takes the same hue at a third of the strength, with the text left the colour it
    /// already was. A solid yellow plate carrying black text is right on a white card and wrong on
    /// a dark panel — it stops reading as a mark on the text and starts reading as a hole punched
    /// through it, and it becomes the brightest thing on screen for a word that is merely a match.
    static func fill(forLightAppearance light: Bool) -> NSColor {
        light ? solidFill : wash
    }

    private static let solidFill = NSColor(srgbRed: 0.98, green: 0.93, blue: 0.42, alpha: 1)

    /// The mark to use where the text already carries a background of its own.
    ///
    /// A terminal transcript comes back as pale glyphs on a dark run — in light mode as well as
    /// dark. Solid yellow over that run buries the run's own text colour, giving pale glyphs on a
    /// bright plate, which reads worse than no mark at all. Letting the run show through keeps it
    /// legible and still says "this is the hit".
    private static let wash = NSColor(srgbRed: 0.98, green: 0.85, blue: 0.30, alpha: 0.32)

    /// `text` with every hit marked, for a card whose body is baked into a bitmap.
    ///
    /// Runs that already have a background of their own take the translucent wash; everything else
    /// takes the solid fill. Which is why this cannot simply set one colour over the whole range.
    static func marked(_ text: NSAttributedString, term: String,
                       forLightAppearance light: Bool) -> NSAttributedString {
        let hits = nsRanges(of: term, in: text.string)
        guard !hits.isEmpty else { return text }

        let marked = NSMutableAttributedString(attributedString: text)
        for hit in hits {
            marked.enumerateAttribute(.backgroundColor, in: hit) { existing, range, _ in
                let hasOwnBackground = (existing as? NSColor)?.alphaComponent ?? 0 > 0.01
                marked.addAttribute(.backgroundColor,
                                    value: hasOwnBackground ? wash : fill(forLightAppearance: light),
                                    range: range)
            }
        }
        return marked
    }
}
