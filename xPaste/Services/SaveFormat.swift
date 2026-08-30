import Foundation

/// What "Save as File…" proposes: a name, an extension, and the bytes to write.
///
/// Every rule here is a guess about content nobody labelled, so all of it is pure — no AppKit, no
/// filesystem, nothing that needs a dialog on screen — and checked directly in `SaveFormatTests`.
/// The guess is only ever a suggestion: the dialog leaves the name editable, so being wrong costs a
/// correction rather than a wrong file.
enum SaveFormat {

    /// The bytes a save writes, in the form they are held rather than as `Data` throughout: a text
    /// item is a string until the moment it is encoded, and a link is not bytes at all until
    /// somebody decides what a `.webloc` looks like. `ItemFileWriter` is where those decisions live.
    enum Payload: Equatable {
        case text(String)
        /// Already-encoded bytes, written through untouched.
        case data(Data)
        /// A page to fetch and write as it is served. Resolved by `ItemFileWriter` at save time,
        /// because the bytes are not on this machine yet.
        case remoteHTML(URL)
        /// The item outlived its content — an image whose pixels have been pruned off disk.
        case unavailable
    }

    struct Suggestion: Equatable {
        let baseName: String
        let ext: String
        let payload: Payload

        var fileName: String { "\(baseName).\(ext)" }

        /// What the Save dialog opens with: the extension on its own.
        ///
        /// No derived name. A name taken from the content read badly far more often than it helped
        /// — a PHP snippet proposed itself as `<?php.php`, a Python one as
        /// `from dataclasses import dataclass.py` — and the user has to read past it either way.
        /// An empty base name also puts the insertion point in front of the dot, which is where
        /// they are about to type. `baseName` still names a dragged file, where nobody is offered
        /// the chance to type one.
        var dialogFileName: String { ".\(ext)" }
    }

    /// The URL a save should actually use.
    ///
    /// Accepting the proposal untouched leaves a file called `.php`: no name, and hidden from the
    /// folder it was just saved into. Anything that amounts to no name at all gets one.
    static func ensuringName(_ url: URL, fallback: String = fallbackName) -> URL {
        // Split by hand rather than through `pathExtension`: Foundation reads `.php` as a dotfile
        // called ".php" with no extension at all, which is exactly the case this exists to catch.
        let component = url.lastPathComponent
        let body = String(component.drop(while: { $0 == "." }))
        let stem: String
        let ext: String
        if let lastDot = body.lastIndex(of: ".") {
            stem = String(body[..<lastDot])
            ext = String(body[body.index(after: lastDot)...])
        } else if component.hasPrefix(".") {
            stem = ""
            ext = body
        } else {
            stem = body
            ext = ""
        }
        guard stem.trimmingCharacters(in: .whitespaces).isEmpty else { return url }
        let name = ext.isEmpty ? fallback : "\(fallback).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Longest first line a file name is allowed to borrow. Past this a name stops identifying the
    /// file and starts being the file, and every Finder column truncates it anyway.
    static let maxBaseNameLength = 60

    /// How much of an item is read to decide what it is.
    ///
    /// A language announces itself at the top — a shebang, an `import`, a `<?php`. Scanning half a
    /// megabyte to find a `function` on line 9000 would not make the answer better, and this runs
    /// on the main thread while the user waits for a dialog.
    private static let scanLimit = 8192

    /// The name a fallback lands on when nothing else survives sanitising.
    private static let fallbackName = "Clipboard"

    // MARK: - What is offered

    /// Whether saving is offered for this kind of item at all.
    ///
    /// File and folder items are left out: they already are files on disk, and dragging the card
    /// into Finder copies them. The card's menu entry and ⌘S both ask here, so neither can act on
    /// something the other refuses.
    static func canSave(_ type: ClipboardContentType) -> Bool {
        switch type {
        case .text, .url, .color, .image: return true
        case .file, .folder:              return false
        }
    }

    // MARK: - The whole suggestion

    /// `imageBytes` is handed in rather than read from the item or from `ClipboardStore`, because an
    /// image's bytes may live on disk instead of in the item. Injecting them keeps this decision
    /// free of the store, and lets the "nothing left to write" case be exercised directly.
    static func suggest(for item: ClipboardItem, imageBytes: Data? = nil) -> Suggestion {
        let name = baseName(for: item)

        switch item.type {
        case .image:
            guard let bytes = imageBytes, !bytes.isEmpty else {
                return Suggestion(baseName: name, ext: "png", payload: .unavailable)
            }
            return Suggestion(baseName: name, ext: imageExtension(for: bytes), payload: .data(bytes))

        case .url:
            let raw = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A `.url` item is text that once parsed as a link; it does not follow that it still
            // does. Anything that will not produce a real URL saves as what it actually is.
            if let url = URL(string: raw), url.scheme != nil {
                return Suggestion(baseName: name, ext: "html", payload: .remoteHTML(url))
            }
            return Suggestion(baseName: name, ext: textExtension(for: raw), payload: .text(raw))

        case .text, .color:
            let body = item.text ?? ""
            return Suggestion(baseName: name, ext: textExtension(for: body), payload: .text(body))

        case .file, .folder:
            // Not offered in the menu — these are already files on disk — but the function stays
            // total rather than trapping on a case the caller is trusted not to pass.
            let paths = item.fileURLs?.map(\.path).joined(separator: "\n") ?? ""
            return Suggestion(baseName: name, ext: "txt", payload: .text(paths))
        }
    }

    // MARK: - Extension, from the bytes of an image

    /// The format an image really is.
    ///
    /// `NSImage.compressedData(maxBytes:)` stores PNG for anything that uses its alpha channel and
    /// JPEG for everything else, while `ClipboardStore` names every one of them `.jpg` on disk. The
    /// stored name is therefore not evidence; the magic bytes are.
    static func imageExtension(for data: Data) -> String {
        // Nothing recognisable: PNG is the safe label, being the format the app writes whenever it
        // is not writing JPEG. Callers that must not guess ask `recognisedImageExtension` instead.
        recognisedImageExtension(for: data) ?? "png"
    }

    /// The same answer, but nil rather than a guess when the bytes say nothing.
    ///
    /// A drag writes a real file for Finder to copy, and a file named for a format it does not
    /// hold is the very thing that made this worth fixing — so that path takes nil for an answer
    /// and hands over the bitmap instead.
    static func recognisedImageExtension(for data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        // TIFF, both byte orders. Not an exotic case: it is what a picture copied on macOS
        // actually is. `NSPasteboard` offers `public.tiff` and nothing else for an ordinary image
        // copy — measured — so leaving it out meant the one format people copy most was the one
        // format this could not name. A drag then wrote no file at all and handed the target the
        // word "Image"; a save wrote TIFF bytes into a file called `.png`.
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) { return "tiff" }
        if data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        // HEIC/HEIF: `ftyp` box at offset 4, brand at 8.
        if data.count >= 12, data[4..<8].elementsEqual([0x66, 0x74, 0x79, 0x70]) {
            let brand = data[8..<12]
            if brand.elementsEqual([0x68, 0x65, 0x69, 0x63])      // heic
                || brand.elementsEqual([0x68, 0x65, 0x69, 0x78])   // heix
                || brand.elementsEqual([0x6D, 0x69, 0x66, 0x31] ) { // mif1
                return "heic"
            }
        }
        // WebP: "RIFF" .... "WEBP"
        if data.count >= 12, data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "webp"
        }
        return nil
    }

    // MARK: - Extension, from the text itself

    /// First match wins, most specific first — parsed structure, then a shebang, then the keywords
    /// a language cannot really be written without.
    ///
    /// The fallback is `.txt` rather than a best effort. A wrong extension is a file that opens in
    /// the wrong application and reads as corrupt; `.txt` is merely unambitious, and true.
    static func textExtension(for raw: String) -> String {
        let head = String(raw.prefix(scanLimit))
        let truncated = raw.count > scanLimit
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "txt" }
        let lower = trimmed.lowercased()

        // JSON is asked of the *whole* string, not the window the language rules read. A payload
        // copied out of a browser's network tab runs to tens of kilobytes, and a truncated one does
        // not parse — every response worth saving would land as `.txt`. The cost is bounded by
        // `TextTransform`'s own 4MB cap and paid once, on an explicit save.
        if TextTransform.jsonObject(in: raw) != nil { return "json" }
        if let ext = structuralExtension(lower: lower) { return ext }
        if let ext = shebangExtension(in: trimmed) { return ext }
        if let ext = languageExtension(trimmed: trimmed) { return ext }
        if isCSV(head, truncated: truncated) { return "csv" }
        return "txt"
    }

    /// Formats that can be recognised by actually parsing them, or by an opening token that exists
    /// for no other purpose.
    private static func structuralExtension(lower: String) -> String? {
        // Ahead of the XML check: an SVG usually carries an XML declaration, and it is still an SVG.
        if lower.hasPrefix("<svg") || (lower.hasPrefix("<?xml") && lower.contains("<svg")) { return "svg" }
        if lower.hasPrefix("<?xml") { return "xml" }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return "html" }
        return nil
    }

    /// The author saying outright what this is, which outranks every keyword further down.
    private static func shebangExtension(in trimmed: String) -> String? {
        guard trimmed.hasPrefix("#!") else { return nil }
        let line = trimmed.prefix(while: { !$0.isNewline }).lowercased()
        // Longest-first, so `python3` is not read as `perl` by a substring that happens to fit and
        // `zsh` is not shadowed by `sh`.
        let interpreters: [(String, String)] = [
            ("python", "py"), ("ruby", "rb"), ("perl", "pl"), ("node", "js"),
            ("bash", "sh"), ("zsh", "sh"), ("ksh", "sh"), ("php", "php"), ("sh", "sh"),
        ]
        return interpreters.first { line.contains($0.0) }?.1
    }

    /// Keywords distinctive enough to name a language.
    ///
    /// Order is load-bearing where two languages share a shape: Swift is asked before Python
    /// because `import Foundation` is an import statement in both grammars; TypeScript and
    /// JavaScript come before CSS because `interface User { id: number; }` is also, letter for
    /// letter, a valid CSS rule.
    private static func languageExtension(trimmed: String) -> String? {
        if trimmed.contains("<?php") { return "php" }

        if trimmed.contains("import SwiftUI") || trimmed.contains("import AppKit")
            || trimmed.contains("import Foundation") {
            if matches(#"(?m)^\s*(func|let|var|struct|class|enum|extension)\s"#, trimmed) { return "swift" }
        }

        if matches(#"(?m)^\s*def\s+\w+\s*\(.*\)\s*:"#, trimmed)
            || matches(#"(?m)^\s*from\s+[\w.]+\s+import\s"#, trimmed) { return "py" }

        if trimmed.contains("package main") && trimmed.contains("func ") { return "go" }

        if trimmed.contains("fn main()") || trimmed.contains("let mut ") { return "rs" }

        if trimmed.contains("#include <") || trimmed.contains("#include \"") {
            let cpp = trimmed.contains("std::") || trimmed.contains("template<")
                || matches(#"(?m)^\s*(class|namespace)\s+\w"#, trimmed)
            return cpp ? "cpp" : "c"
        }

        if matches(#"(?m)^\s*(public|private|protected)\s+(static\s+|final\s+|abstract\s+)*class\s+\w"#, trimmed) {
            return "java"
        }

        if matches(#"(?i)(?m)^\s*(select\b[\s\S]*\bfrom\b|insert\s+into\b|update\s+\w+\s+set\b|create\s+(table|view|index)\b|alter\s+table\b|delete\s+from\b)"#, trimmed) {
            return "sql"
        }

        if isJavaScriptFamily(trimmed) {
            let typed = trimmed.contains("interface ")
                || matches(#":\s*(string|number|boolean|void|any|unknown)\b"#, trimmed)
                || matches(#"(?m)^\s*type\s+\w+\s*="#, trimmed)
            return typed ? "ts" : "js"
        }

        if matches(#"[\w\-\.\#\[\]]+\s*\{[^}]*[\w-]+\s*:\s*[^;}]+;"#, trimmed) { return "css" }

        if isMarkdown(trimmed) { return "md" }

        return nil
    }

    private static func isJavaScriptFamily(_ text: String) -> Bool {
        text.contains("function ") || text.contains("=>") || text.contains("require(")
            || text.contains("console.log(") || text.contains("export default")
            || matches(#"(?m)^\s*(const|let|var)\s+\w+\s*="#, text)
    }

    /// A heading alone is not enough: `# set up the machine` is a shell comment written exactly the
    /// same way. Markdown has to show something a comment never does — a link, a fenced block, or
    /// more than one heading.
    private static func isMarkdown(_ text: String) -> Bool {
        if matches(#"\[[^\]]*\]\([^)]*\)"#, text) { return true }
        if text.contains("```") { return true }
        let headings = text.ranges(ofPattern: #"(?m)^#{1,6}\s+\S"#).count
        return headings >= 2
    }

    /// Rows of the same shape. Deliberately strict about "the same": prose with a comma in it must
    /// not become a spreadsheet, and the tell is that prose lines never agree on where the commas
    /// go.
    private static func isCSV(_ head: String, truncated: Bool) -> Bool {
        var lines = head.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // The last line of a truncated read is a fragment, and a fragment's comma count means
        // nothing.
        if truncated, !lines.isEmpty { lines.removeLast() }
        // Three, not two: a note and its sign-off break in the same place often enough, and two
        // matching lines are a coincidence rather than a table.
        guard lines.count >= 3 else { return false }
        guard !lines.contains(where: { $0.contains("{") || $0.contains("<") || $0.contains(";") }) else {
            return false
        }
        let counts = lines.prefix(20).map { line in line.filter { $0 == "," }.count }
        guard let first = counts.first, first >= 1 else { return false }
        guard counts.allSatisfy({ $0 == first }) else { return false }
        // Rows are split on bare commas; prose puts a space after every one. A file where every
        // comma is followed by a space is a list of sentences, whatever its shape.
        return lines.prefix(20).contains { line in
            zip(line, line.dropFirst()).contains { $0 == "," && $1 != " " }
                || line.hasSuffix(",")
        }
    }

    // MARK: - Name

    /// A name the user typed onto the card wins over anything derived from the content: naming an
    /// item is the whole point of the Pin tab as a snippet library, and that name is what they will
    /// look for on disk.
    static func baseName(for item: ClipboardItem) -> String {
        if let label = item.label {
            let cleaned = sanitised(label)
            if !cleaned.isEmpty { return cleaned }
        }

        switch item.type {
        case .image:
            return "Image " + Self.timestampFormatter.string(from: item.timestamp)

        case .url:
            let raw = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let host = URL(string: raw)?.host {
                let cleaned = sanitised(host)
                if !cleaned.isEmpty { return cleaned }
            }
            return derivedFromText(item.text)

        case .text, .color:
            return derivedFromText(item.text)

        case .file, .folder:
            if let name = item.fileURLs?.first?.lastPathComponent {
                let cleaned = sanitised((name as NSString).deletingPathExtension)
                if !cleaned.isEmpty { return cleaned }
            }
            return fallbackName
        }
    }

    private static func derivedFromText(_ text: String?) -> String {
        guard let line = text?.components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return fallbackName }
        let cleaned = sanitised(line)
        return cleaned.isEmpty ? fallbackName : cleaned
    }

    /// What a file name may not contain, and what it should not start with.
    ///
    /// `/` is the path separator and `:` is what the Finder still shows a path separator as, so
    /// neither survives. A leading dot would hide the file from the folder the user just saved it
    /// into, which is never what they meant.
    static func sanitised(_ raw: String) -> String {
        let stripped = raw.unicodeScalars
            .map { scalar -> Character in
                if scalar == "/" || scalar == ":" { return " " }
                if CharacterSet.controlCharacters.contains(scalar) { return " " }
                return Character(scalar)
            }
        let collapsed = String(stripped)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let unhidden = collapsed.drop(while: { $0 == "." })
        return withinByteBudget(String(unhidden.prefix(maxBaseNameLength)))
            .trimmingCharacters(in: .whitespaces)
    }

    /// A path component is limited to 255 UTF-8 bytes, not to 255 characters, and sixty flags or
    /// skin-toned emoji sail past that — the write would then fail at the very last step, after the
    /// user had already chosen where to put the file. Cut by whole characters so nothing is left
    /// half-encoded, and short of the limit to leave room for the extension.
    private static let maxBaseNameBytes = 200

    private static func withinByteBudget(_ name: String) -> String {
        guard name.utf8.count > maxBaseNameBytes else { return name }
        var out = ""
        var bytes = 0
        for character in name {
            let width = String(character).utf8.count
            if bytes + width > maxBaseNameBytes { break }
            out.append(character)
            bytes += width
        }
        return out
    }

    /// Fixed format and a fixed locale, so an image saved on a Vietnamese Mac is named the same way
    /// as on an English one — and the same way macOS names a screenshot.
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    // MARK: - Regex helpers

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

private extension String {
    /// Every match of `pattern`, used only to count them.
    func ranges(ofPattern pattern: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var cursor = startIndex
        while cursor < endIndex,
              let hit = range(of: pattern, options: .regularExpression, range: cursor..<endIndex) {
            guard !hit.isEmpty else { break }
            found.append(hit)
            cursor = hit.upperBound
        }
        return found
    }
}
