import Foundation

/// One piece of a release's notes, lifted out of the raw markdown.
///
/// The view renders these one at a time. *Inline* markdown — `**bold**`, `` `code` ``,
/// `[link](url)` — is left in `text` untouched, because `AttributedString(markdown:)` handles that
/// at the view layer. Splitting into blocks has to happen here precisely because that initialiser
/// understands nothing else: hand it a whole release body and it returns one run-on paragraph with
/// every heading and list flattened into it.
enum ReleaseNoteBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(indent: Int, text: String)
    case ordered(indent: Int, number: Int, text: String)
    case code(String)
    case rule
}

/// A small markdown reader, sized for GitHub release notes and nothing else.
///
/// Knowingly short of CommonMark: no tables, no reference links, no nested block structures. None
/// of that appears in this project's release notes, and supporting it would be code to maintain and
/// a larger surface to be wrong on, in aid of nothing anyone would see.
enum ReleaseNotesMarkdown {

    static func parse(_ markdown: String) -> [ReleaseNoteBlock] {
        var blocks: [ReleaseNoteBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var insideCodeFence = false

        // Consecutive prose lines join into one paragraph, as markdown means them to. Left as
        // separate blocks, a paragraph that happens to be wrapped renders as though the notes had
        // been broken across lines at random.
        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.components(separatedBy: "\n") {
            // A tab counts as four spaces so indentation measures the same however it was typed.
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if insideCodeFence {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    insideCodeFence = false
                } else {
                    flushParagraph()
                    insideCodeFence = true
                }
                continue
            }
            if insideCodeFence {
                codeLines.append(rawLine)      // inside a fence the line stands exactly as written
                continue
            }

            if trimmed.isEmpty { flushParagraph(); continue }

            // Strip any `>` and classify what is left like any other line. Quoted blocks in these
            // notes still contain headings and bullets; left in place the marker lands in the
            // middle of the text and the whole quote collapses into one paragraph. There is
            // deliberately no quote block of its own — rendering the contents plainly is enough,
            // and it saves the view a case.
            let content = strippingQuoteMarkers(trimmed)
            if content.isEmpty { flushParagraph(); continue }        // a line holding only `>`

            // Rules are tested before bullets: `***` and `---` both open with a bullet marker.
            if isRule(content) {
                flushParagraph()
                // Two rules in a row draw as one thick line and read as a mistake. Keep one.
                if blocks.last != .rule { blocks.append(.rule) }
                continue
            }

            if let heading = parseHeading(content) { flushParagraph(); blocks.append(heading); continue }

            let indent = indentLevel(of: line)
            if let bullet = parseBullet(content, indent: indent) { flushParagraph(); blocks.append(bullet); continue }
            if let ordered = parseOrdered(content, indent: indent) { flushParagraph(); blocks.append(ordered); continue }

            paragraphLines.append(content)
        }

        // A fence left unclosed at the end of the notes: show it rather than swallow the contents.
        if insideCodeFence, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()

        // A rule at either end separates nothing — it just draws a line against the edge of the
        // box. These notes do end with `---`, so the trailing case is real rather than defensive.
        while blocks.first == .rule { blocks.removeFirst() }
        while blocks.last == .rule { blocks.removeLast() }
        return blocks
    }

    // MARK: - Recognising a line

    /// Drops every leading `>`, nested ones included, along with the space each is followed by.
    private static func strippingQuoteMarkers(_ trimmed: String) -> String {
        var content = Substring(trimmed)
        while content.first == ">" {
            content = content.dropFirst().drop { $0 == " " }
        }
        return String(content)
    }

    /// `---`, `***`, `___`: three or more of one character, spaces allowed between (`* * *`).
    private static func isRule(_ trimmed: String) -> Bool {
        let dense = trimmed.filter { !$0.isWhitespace }
        guard dense.count >= 3, let first = dense.first, "-*_".contains(first) else { return false }
        return dense.allSatisfy { $0 == first }
    }

    /// `#` … `######`, a space, then the text. A closing run of `#` is dropped.
    private static func parseHeading(_ trimmed: String) -> ReleaseNoteBlock? {
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    /// `-`, `*` or `+`, a space, then the text.
    private static func parseBullet(_ trimmed: String, indent: Int) -> ReleaseNoteBlock? {
        guard let marker = trimmed.first, "-*+".contains(marker) else { return nil }
        let rest = trimmed.dropFirst()
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .bullet(indent: indent, text: text)
    }

    /// `1.` or `1)`, a space, then the text.
    private static func parseOrdered(_ trimmed: String, indent: Int) -> ReleaseNoteBlock? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " else { return nil }
        let text = after.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .ordered(indent: indent, number: number, text: text)
    }

    /// Two spaces to a level, capped at three, so a deeply nested list cannot push its text out of
    /// the box.
    private static func indentLevel(of line: String) -> Int {
        let spaces = line.prefix { $0 == " " }.count
        return min(spaces / 2, 3)
    }
}
