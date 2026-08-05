import Foundation

/// Reads the beginning of a file when — and only when — it turns out to be readable text.
///
/// Decided from the bytes rather than from the extension or `UTType`: a file with no extension
/// (`.env`, `Dockerfile`, `LICENSE`) is still text, and `UTType` answers depend on which apps have
/// registered which extensions, so the same file can read as text on one Mac and not on another.
enum TextFileReader {

    /// Whether these bytes look like text rather than a binary format.
    ///
    /// One rule, one tell: a NUL byte. Every format that is not text — PDF, zip, Office documents,
    /// images — carries them within the first few kilobytes, and text essentially never does.
    static func isProbablyText(_ data: Data) -> Bool {
        !data.contains(0)
    }

    /// UTF-8, tolerating a sequence cut in half by the byte budget.
    ///
    /// Reading stops at a byte count, not a character count, so the last character is regularly
    /// split. Vietnamese runs 2–3 bytes per accented character, making this the common case rather
    /// than an edge case — and `String(data:encoding:)` rejects the *entire* block when it happens.
    /// Dropping up to three trailing bytes reaches a character boundary from anywhere inside a
    /// sequence; failing even then means the bytes are not UTF-8 at all, which is the answer.
    static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        var trimmed = data
        for _ in 0..<3 {
            guard !trimmed.isEmpty else { return nil }
            trimmed = Data(trimmed.dropLast())
            if let text = String(data: trimmed, encoding: .utf8) { return text }
        }
        return nil
    }

    /// The first `maxBytes` of `url` as text, or nil if it is not a readable text file.
    ///
    /// Callers pick their own budget: a card shows a few hundred characters, while the popover
    /// scrolls and can afford far more.
    static func read(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty,
              isProbablyText(data),
              let text = decode(data), !text.isEmpty
        else { return nil }
        return text
    }
}
