import Foundation

/// A path copied out of an SFTP client, without the server it came from.
///
/// A file browser's "copy path" hands over `sftp://10.0.0.5/home/www`, but the places a path is
/// pasted into — a terminal, a config file, a `cd` — never want the authority in front of it.
///
/// Pure string→string, the way `TextTransform` is, so the whole rule table is testable without a
/// pasteboard or a running app. `ClipboardMonitor` is what applies it.
enum RemotePath {
    /// The schemes a copied server path arrives under.
    ///
    /// `ssh` and `scp` are deliberately absent: they are shell targets rather than things a file
    /// browser copies. `http`/`https` are absent for a harder reason — they are the two schemes
    /// `ClipboardItem.contentType` promotes to a `.url` item, and stripping one would leave a Link
    /// card showing a meaningless fragment.
    static let schemes: Set<String> = ["sftp", "ftp", "ftps"]

    /// The path `text` reduces to, or nil when there is nothing to strip.
    ///
    /// Nil rather than the input unchanged, matching `TextTransform.apply`: the caller's question
    /// is "is there anything to do here at all", and a string equal to what went in is a worse way
    /// to answer it than an empty optional.
    static func strip(_ text: String) -> String? {
        // Both guards before anything is allocated. This runs on the main thread from
        // `ClipboardMonitor.poll`, for every text copy anyone makes, and the overwhelmingly common
        // case is text that is not a path at all — so reaching that verdict must not depend on how
        // much text there is. Measured before this was here: 60ms to reject a 4MB paste (Debug),
        // all of it spent trimming and splitting a string that the first seven characters had
        // already ruled out. See `RemotePathPerformanceTests`.
        guard startsWithRemoteScheme(text), text.utf8.count <= sizeLimit else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // One URL per line: selecting several folders and copying gives a block of them. Blank
        // lines are dropped rather than failed on — a trailing newline is not a reason to give up
        // on the whole block.
        let lines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var paths: [String] = []
        paths.reserveCapacity(lines.count)
        for line in lines {
            // Every line or none. A partial rewrite would leave a list where some entries had lost
            // their host and others had not, which is harder to make sense of than either outcome.
            guard let path = path(of: line) else { return nil }
            paths.append(path)
        }
        return paths.joined(separator: "\n")
    }

    /// How much text is worth examining at all.
    ///
    /// A block of copied server paths is a handful of lines; a quarter-megabyte of them would be
    /// some ten thousand. Past this, whatever was copied is something other than a path list, and
    /// the whole-string work is not worth doing to find that out. The same bound, for the same
    /// reason, as `TextTransform.jsonProbeLimit`.
    private static let sizeLimit = 256 * 1024

    /// `"ftps://"` and `"sftp://"`, the longest of the prefixes.
    private static let schemePrefixLength = 7

    /// Whether the text can be a remote path at all, decided without allocating.
    ///
    /// Exact rather than a heuristic, and that is what makes it safe as an early-out: the first
    /// line has to be a remote URL for any of the block to qualify, so the first non-whitespace
    /// characters have to be one of the schemes.
    private static func startsWithRemoteScheme(_ text: String) -> Bool {
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return false }
        let head = text[start...].prefix(schemePrefixLength).lowercased()
        return schemes.contains { head.hasPrefix("\($0)://") }
    }

    /// The path of one line, when the whole of that line is a remote URL carrying one.
    ///
    /// The whole line, because `URL(string:)` refuses a string with spaces in it — which is what
    /// keeps a sentence that merely mentions a URL from being rewritten into a fragment of itself.
    private static func path(of line: String) -> String? {
        guard let url = URL(string: line),
              let scheme = url.scheme,
              schemes.contains(scheme.lowercased())
        else { return nil }

        // Decoded: `%C6%B0` belonged to the URL, and the URL is what is being thrown away. What is
        // left is a path, and a path with a Vietnamese folder name in it should read as one.
        let path = url.path(percentEncoded: false)

        // `sftp://host` on its own names no path, so there is nothing to rewrite it to. A bare `/`
        // is not this case: that is the server's root, and a real answer.
        return path.isEmpty ? nil : path
    }
}
