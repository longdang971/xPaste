import AppKit

/// Rewrites the font-table entries `NSAttributedString.rtf(from:documentAttributes:)` writes for
/// system-face runs, so the system font (San Francisco) survives an RTF round trip instead of
/// silently becoming Helvetica Neue.
///
/// ## The bug this undoes
///
/// Cocoa's RTF *writer* has no way to name `.AppleSystemUIFont` (the system face) in a `\fonttbl`
/// entry, so it substitutes some `HelveticaNeue*` name instead — measured, one weight at a time:
/// light/regular/medium/semibold/bold all come out as a Helvetica Neue variant, and medium and
/// semibold collide on the very same name. The *reader* has no such trouble: given a table entry
/// that actually names a system face (`.AppleSystemUIFont`, `.AppleSystemUIFontBold`, …), it
/// resolves it correctly, traits and all. So the fix only has to patch what the writer put in the
/// table — the document body, colour table and everything else is left alone.
///
/// ## How a table entry is chosen
///
/// A run's own `fontName` is not always what its table entry should say: bold and italic applied as
/// *traits* (`\b`, `\i`) share one entry with the plain face they were toggled from, rather than
/// getting an entry of their own — a document with system regular, a bolded word and an italicised
/// word writes a *single* table entry, and the traits are expressed in the body. So the candidate
/// for a table entry is not simply "each run's font" but "a name that, written into that one entry
/// alongside each run's own trait bits, reads every run in the group back correctly" — checked by
/// literally doing the round trip, never assumed.
///
/// Nothing here is hardcoded. What the writer actually calls a given font, and what a candidate
/// entry reads back as, are both derived by encoding (or decoding) a one-character probe and
/// reading the result, so a macOS release that changes the substitution does not silently break
/// this.
enum SystemFontRTF {

    /// Rewrites `rtf`'s font table so system-face entries name the real system font, or returns it
    /// untouched when that can't be done unambiguously. `attributed` is the string `rtf` was encoded
    /// from — read for the fonts it used, never re-encoded.
    static func fixup(rtf: Data, attributed: NSAttributedString) -> Data {
        let whole = NSRange(location: 0, length: attributed.length)

        // The distinct system-face fonts actually in use, one representative per `fontName`.
        var systemFonts: [String: NSFont] = [:]
        attributed.enumerateAttribute(.font, in: whole, options: []) { value, _, _ in
            guard let font = value as? NSFont, RichTextHTML.isSystemFace(font) else { return }
            systemFonts[font.fontName] = font
        }
        guard !systemFonts.isEmpty else { return rtf }

        // What the writer actually calls each of them, alone — context-independent: measured,
        // encoding a font next to others names it exactly what encoding it by itself does.
        var probes: [String: WriterProbe] = [:]
        for (name, font) in systemFonts {
            guard let probe = writerProbe(for: font) else { return rtf }
            probes[name] = probe
        }

        // Fonts that share a table name share one physical entry, so there is only one name left
        // to choose per group. A candidate is one member's own `fontName`; it is accepted only once
        // *every* member of the group — decoded from that candidate plus its own trait bits — comes
        // back as itself (same system weight, same bold/italic). The whole rewrite is refused the
        // moment a group has no candidate that works for everyone in it: that is exactly the case of
        // two system weights the writer collapses onto one name (medium and semibold both write
        // "HelveticaNeue-Medium"). There is no single entry that reads both back correctly, so
        // picking one anyway would silently turn one weight into the other.
        var renaming: [String: String] = [:]
        let groups = Dictionary(grouping: probes.keys, by: { probes[$0]!.tableName })
        for (tableName, members) in groups {
            guard let winner = members.first(where: { candidate in
                members.allSatisfy { verifies(candidate, as: probes[$0]!, against: systemFonts[$0]!) }
            }) else { return rtf }
            renaming[tableName] = winner
        }

        // Refuse if a non-system run would be written under one of those same table names — the
        // real-world case is a genuine Helvetica Neue run: it writes the identical name, and a
        // document holding both collapses them onto the same physical entry, so renaming it would
        // silently turn the genuine Helvetica Neue text into the system font too.
        var ambiguous = false
        attributed.enumerateAttribute(.font, in: whole, options: []) { value, _, stop in
            guard let font = value as? NSFont, !RichTextHTML.isSystemFace(font) else { return }
            guard let probe = writerProbe(for: font) else {
                ambiguous = true
                stop.pointee = true
                return
            }
            if renaming[probe.tableName] != nil {
                ambiguous = true
                stop.pointee = true
            }
        }
        guard !ambiguous else { return rtf }

        // Only the font table itself changes — never the body, the colour table, or anything else.
        guard let (text, encoding) = rtfText(rtf),
              let rewritten = rewriteFontTable(in: text, renaming: renaming),
              let data = rewritten.data(using: encoding)
        else { return rtf }
        return data
    }

    // MARK: - What the writer calls a font

    private struct WriterProbe {
        /// The name the font table entry carries.
        let tableName: String
        /// Whether the writer expressed this exact font as that entry plus a body-level `\b`/`\i`,
        /// rather than the entry alone being enough to say what it is.
        let bold: Bool
        let italic: Bool
    }

    /// Encodes `font` alone and reads back what the writer called it.
    private static func writerProbe(for font: NSFont) -> WriterProbe? {
        let probe = NSAttributedString(string: "x", attributes: [.font: font])
        guard let data = probe.rtf(from: NSRange(location: 0, length: 1), documentAttributes: [:]),
              let (text, _) = rtfText(data),
              let tableRange = fontTableRange(in: text),
              let name = fontEntryName(in: text[tableRange])
        else { return nil }
        let body = text[tableRange.upperBound...]
        return WriterProbe(tableName: name,
                           bold: containsControlWord(body, "b"),
                           italic: containsControlWord(body, "i"))
    }

    /// Whether writing `candidate` as the font table entry, together with `probe`'s own trait bits,
    /// reads back as `font` — same system face, same bold, same italic, same weight. Compared this
    /// way rather than by `fontName`: the reader can hand back a differently-spelled but equivalent
    /// font (`.SFNS-Bold` for a run that was built as `.AppleSystemUIFontBold`), and that is still
    /// correct.
    private static func verifies(_ candidate: String, as probe: WriterProbe, against font: NSFont) -> Bool {
        guard let restored = decode(entry: candidate, bold: probe.bold, italic: probe.italic),
              RichTextHTML.isSystemFace(restored)
        else { return false }
        let manager = NSFontManager.shared
        let want = manager.traits(of: font)
        let got = manager.traits(of: restored)
        return want.contains(.boldFontMask) == got.contains(.boldFontMask)
            && want.contains(.italicFontMask) == got.contains(.italicFontMask)
            && manager.weight(of: restored) == manager.weight(of: font)
    }

    /// Decodes a one-character document whose only run names `entry` in the font table, with
    /// `bold`/`italic` as body-level traits — the same shape a real font table entry plus a run
    /// takes, built by hand so this doesn't depend on `NSAttributedString.rtf(from:)` at all.
    private static func decode(entry: String, bold: Bool, italic: Bool) -> NSFont? {
        var traits = ""
        if bold { traits += "\\b" }
        if italic { traits += "\\i" }
        let rtf = "{\\rtf1\\ansi\\ansicpg1252{\\fonttbl\\f0\\fnil\\fcharset0 \(entry);}\\f0\(traits)\\fs26 x}"
        guard let data = rtf.data(using: .ascii),
              let restored = NSAttributedString(rtf: data, documentAttributes: nil),
              restored.length > 0
        else { return nil }
        return restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    // MARK: - Reading and rewriting the font table, textually

    /// RTF's control stream is always 7-bit ASCII — anything wider is escaped — so decoding this way
    /// and re-encoding with the same `String.Encoding` is exact for everything this file does not
    /// deliberately edit.
    private static func rtfText(_ data: Data) -> (String, String.Encoding)? {
        if let text = String(data: data, encoding: .ascii) { return (text, .ascii) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .isoLatin1) }
        return nil
    }

    /// The span of the `{\fonttbl …}` group, braces included, so an edit can be scoped to exactly
    /// that group and nowhere else — a font name could plausibly turn up in the document's own
    /// text, and this is what keeps a rewrite from ever touching that.
    private static func fontTableRange(in text: String) -> Range<String.Index>? {
        guard let marker = text.range(of: "\\fonttbl"),
              let openBrace = text[..<marker.lowerBound].lastIndex(of: "{")
        else { return nil }
        var depth = 0
        var index = openBrace
        while index < text.endIndex {
            let char = text[index]
            if char == "\\", text.index(after: index) < text.endIndex {
                let next = text[text.index(after: index)]
                if next == "{" || next == "}" || next == "\\" {
                    // An escaped brace/backslash inside a font name — doesn't happen for any name
                    // this file deals with, but skipping it keeps the depth count honest if it did.
                    index = text.index(index, offsetBy: 2)
                    continue
                }
            }
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 { return openBrace..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The name inside a single-entry font table group, e.g. `HelveticaNeue-Medium` out of
    /// `{\fonttbl\f0\fnil\fcharset0 HelveticaNeue-Medium;}`. Only ever called on a `writerProbe`'s
    /// own one-font table, so there is exactly one entry to find: every leading control word is
    /// skipped, and what remains after the space that ends the last one, up to `;`, is the name.
    private static func fontEntryName(in text: Substring) -> String? {
        var rest = text
        if rest.first == "{" { rest = rest.dropFirst() }
        while rest.first == "\\" {
            rest = rest.dropFirst()
            while let char = rest.first, char.isLetter { rest = rest.dropFirst() }
            if rest.first == "-" { rest = rest.dropFirst() }
            while let char = rest.first, char.isNumber { rest = rest.dropFirst() }
            if rest.first == " " {
                rest = rest.dropFirst()
                break
            }
            guard rest.first == "\\" else { break }
        }
        guard let semicolon = rest.firstIndex(of: ";") else { return nil }
        return String(rest[..<semicolon])
    }

    /// Whether a bare control word — `\b`, not `\background` (not real RTF) or `\b0` (bold turned
    /// back off) — appears anywhere in `text`. Scoped to a `writerProbe`'s own freshly-encoded
    /// single-character document, which never turns a trait back off, so "the letters right after a
    /// backslash are exactly `word`" is unambiguous here.
    private static func containsControlWord(_ text: Substring, _ word: String) -> Bool {
        for piece in text.split(separator: "\\", omittingEmptySubsequences: true) {
            var letters = ""
            for char in piece {
                guard char.isLetter else { break }
                letters.append(char)
            }
            if letters == word { return true }
        }
        return false
    }

    /// Replaces `renaming`'s keys with their values inside the font table only — a literal
    /// substitution of `"name;"`, which is unambiguous because RTF puts nothing but the terminating
    /// `;` directly after a font name.
    private static func rewriteFontTable(in text: String, renaming: [String: String]) -> String? {
        guard let range = fontTableRange(in: text) else { return nil }
        var table = String(text[range])
        for (old, new) in renaming {
            table = table.replacingOccurrences(of: "\(old);", with: "\(new);")
        }
        var result = text
        result.replaceSubrange(range, with: table)
        return result
    }
}
