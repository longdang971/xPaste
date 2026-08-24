import Foundation

/// Puts a saved page's encoding back into the page.
///
/// A server usually says what a document is encoded in through the HTTP `Content-Type` header
/// rather than through the markup — the Chrome Web Store is one such page, and so is most of
/// Google. That header exists only for as long as the response does. Written to a file it is gone,
/// and a browser opening the file has nothing left to go on: HTML's own fallback for an undeclared
/// document is windows-1252, so every accented character comes back as mojibake (`Cửa hàng` reads
/// as `Cá»­a hÃ ng`).
///
/// So the header is written into the document as a `<meta charset>` before it lands on disk. This
/// is deliberately the smallest edit that fixes it: one tag, inserted after the opening `<head>`,
/// with every other byte left exactly as it was served. A document that already declares its own
/// encoding — in either the modern or the `http-equiv` form — or that carries a byte-order mark is
/// left completely alone.
///
/// Pure, so it can be checked byte for byte in `HTMLCharsetTests` without a network or a disk.
enum HTMLCharset {

    /// How far in the opening tags are looked for.
    ///
    /// Browsers pre-scan the first 1024 bytes of a document for an encoding and stop. Scanning
    /// further than that for an *existing* declaration is harmless and catches a slow `<head>`;
    /// what matters is that the tag this inserts lands inside that first kilobyte, which it does
    /// whenever the `<head>` itself does.
    private static let prescanLimit = 4096

    /// `data` with a `<meta charset>` added when the document has none, or `data` unchanged.
    ///
    /// `charset` is what the response claimed, if it claimed anything. When it claimed nothing the
    /// bytes are asked instead — but only far enough to tell UTF-8 from "no idea", never far
    /// enough to guess between two legacy encodings, because a wrong guess written into the file
    /// is worse than the browser's own fallback.
    static func declaring(_ data: Data, charset: String?) -> Data {
        guard !hasByteOrderMark(data), !declaresCharset(data) else { return data }
        guard let anchor = insertionPoint(in: data) else { return data }
        guard let name = resolvedName(charset, data: data) else { return data }

        var out = data.prefix(anchor)
        out.append(Data("<meta charset=\"\(name)\">".utf8))
        out.append(data.suffix(from: data.startIndex + anchor))
        return Data(out)
    }

    // MARK: - What the document already says

    private static func hasByteOrderMark(_ data: Data) -> Bool {
        data.starts(with: [0xEF, 0xBB, 0xBF])       // UTF-8
            || data.starts(with: [0xFF, 0xFE])      // UTF-16 LE
            || data.starts(with: [0xFE, 0xFF])      // UTF-16 BE
    }

    /// Whether a `<meta>` tag in the opening of the document mentions a charset.
    ///
    /// Only inside a `<meta …>` tag: a bare search for "charset" hits `c.charset="UTF-8"` in the
    /// script loader of the very page that prompted this, and reading that as a declaration would
    /// leave the file broken in exactly the case it has to fix.
    private static func declaresCharset(_ data: Data) -> Bool {
        let window = Array(data.prefix(prescanLimit))
        var index = 0
        while let start = find(ascii: "<meta", in: window, from: index) {
            let end = find(byte: UInt8(ascii: ">"), in: window, from: start) ?? window.count
            if find(ascii: "charset", in: window, from: start, before: end) != nil { return true }
            index = end
            if index >= window.count { break }
        }
        return false
    }

    // MARK: - Where the tag goes

    /// Just after the opening `<head>`, or failing that just after `<html>`.
    ///
    /// Nothing else is offered a home. A fragment with neither tag is not a document anybody opens
    /// in a browser, and prepending markup to it would change what the user copied.
    private static func insertionPoint(in data: Data) -> Int? {
        let window = Array(data.prefix(prescanLimit))
        for tag in ["<head", "<html"] {
            guard let start = find(ascii: tag, in: window, from: 0) else { continue }
            // `<header>` is not `<head>`: the character after the name has to end it.
            let after = start + tag.count
            if after < window.count {
                let next = window[after]
                let ends = next == UInt8(ascii: ">") || next == UInt8(ascii: " ")
                    || next == UInt8(ascii: "\n") || next == UInt8(ascii: "\r") || next == UInt8(ascii: "\t")
                guard ends else { continue }
            }
            guard let close = find(byte: UInt8(ascii: ">"), in: window, from: start) else { continue }
            return close + 1
        }
        return nil
    }

    // MARK: - What to call it

    /// The charset to write, or nil when nothing can be said honestly.
    private static func resolvedName(_ claimed: String?, data: Data) -> String? {
        if let claimed, let safe = sanitised(claimed) { return safe }
        // No usable header. Non-ASCII bytes that decode as UTF-8 are UTF-8 in every practical
        // sense; anything else is a legacy encoding this has no way to name.
        guard containsNonASCII(data), String(data: data, encoding: .utf8) != nil else { return nil }
        return "utf-8"
    }

    /// A charset name is remote input, and it is about to be written inside an HTML attribute. Only
    /// the shape a real name has gets through — a quote in there would close the attribute and let
    /// the header rewrite the user's document.
    private static func sanitised(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.count <= 40 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.:+")
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return name
    }

    private static func containsNonASCII(_ data: Data) -> Bool {
        data.contains { $0 > 0x7F }
    }

    // MARK: - Byte search

    /// ASCII-case-insensitive search, on bytes rather than on a `String`: the document may be in an
    /// encoding that does not decode at all, and it still has to be searchable and writable.
    private static func find(ascii needle: String, in haystack: [UInt8],
                             from start: Int, before end: Int? = nil) -> Int? {
        let limit = min(end ?? haystack.count, haystack.count)
        let pattern = Array(needle.lowercased().utf8)
        guard !pattern.isEmpty, limit >= pattern.count else { return nil }
        var i = max(start, 0)
        while i + pattern.count <= limit {
            var matched = true
            for (offset, byte) in pattern.enumerated() where lowered(haystack[i + offset]) != byte {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private static func find(byte: UInt8, in haystack: [UInt8], from start: Int) -> Int? {
        var i = max(start, 0)
        while i < haystack.count {
            if haystack[i] == byte { return i }
            i += 1
        }
        return nil
    }

    private static func lowered(_ byte: UInt8) -> UInt8 {
        (byte >= 65 && byte <= 90) ? byte + 32 : byte
    }
}
