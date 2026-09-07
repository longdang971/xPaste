import Foundation

/// A path copied out of an SFTP client, without the server it came from.
///
/// A file browser's "copy path" hands over `sftp://10.0.0.5/home/www`, but the places a path is
/// pasted into — a terminal, a config file, a `cd` — never want the authority in front of it.
///
/// Pure string→string, the way `TextTransform` is, so the whole rule table is testable without a
/// pasteboard or a running app. `ClipboardMonitor` is what applies it.
enum RemotePath {
    /// The scheme a copied server path arrives under.
    ///
    /// Only one. It stays a set because that is the shape both callers ask their question in, and
    /// narrowing it to a constant would buy nothing.
    ///
    /// `ssh` and `scp` are absent: they are shell targets rather than things a file browser copies.
    /// `http`/`https` are absent for a harder reason — they are the two schemes
    /// `ClipboardItem.contentType` promotes to a `.url` item, and stripping one would leave a Link
    /// card showing a meaningless fragment.
    ///
    /// `ftp` and `ftps` were here and were taken out. They are not only file-browser "copy path"
    /// schemes; they are ordinary resource locators that appear on download pages and in
    /// documentation — and `contentType` does *not* promote them, so an `ftp://` URL arrived as
    /// plain text and was rewritten to its path. Unrecoverably: the rewrite replaces the pasteboard
    /// and the history keeps only the stripped form. `sftp://` carries no such traffic; it is what
    /// a file browser puts on the clipboard and essentially nothing else.
    static let schemes: Set<String> = ["sftp"]

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

    /// The length of `"sftp://"`.
    private static let schemePrefixLength = 7

    /// How much leading whitespace the scheme is allowed to sit behind.
    ///
    /// The search for the first non-whitespace character is otherwise proportional to the whole
    /// text, and it runs *before* the size bound has had a chance to reject anything — so the
    /// bound cannot protect it. A 4MB whitespace-headed paste measured at 180ms on the main
    /// thread, inside a 100ms poll. A region of empty spreadsheet cells is exactly that shape:
    /// tabs and newlines all the way down.
    ///
    /// A copied path sits behind a newline or a couple of spaces at most. Past this the text is
    /// not one, and it is refused — the safe direction, since nothing is then written.
    private static let leadingWhitespaceAllowance = 32

    /// Whether the text can be a remote path at all, decided without allocating and in bounded
    /// time.
    ///
    /// Exact rather than a heuristic, and that is what makes it safe as an early-out: the first
    /// line has to be a remote URL for any of the block to qualify, so the first non-whitespace
    /// characters have to be one of the schemes.
    private static func startsWithRemoteScheme(_ text: String) -> Bool {
        // Long enough to hold the allowance and a whole scheme behind it, so a scheme that starts
        // anywhere within the allowance is still seen in full.
        let head = text.prefix(leadingWhitespaceAllowance + schemePrefixLength)
        guard let start = head.firstIndex(where: { !$0.isWhitespace }) else { return false }
        let candidate = head[start...].prefix(schemePrefixLength).lowercased()
        return schemes.contains { candidate.hasPrefix("\($0)://") }
    }

    /// Everything a decoded path may not contain.
    ///
    /// Derived from `CharacterSet.newlines` rather than listed by hand, and that is the point:
    /// it is the set `strip` splits its own input with, so anything in it that reached a path
    /// would come back as two lines from that same splitter. The hand-written version listed LF,
    /// CR and NUL, and so missed VT, FF, NEL, LS and PS — every one of them reachable from an
    /// ordinary-looking `%0B`, `%0C`, `%C2%85`, `%E2%80%A8` or `%E2%80%A9`. Deriving it is what
    /// keeps the guard and the splitter from drifting apart again.
    ///
    /// NUL is added on its own account: no POSIX path may contain one, and it would travel into
    /// the pasteboard and the store as a string nothing downstream expects.
    ///
    /// A tab is in neither set, and is left alone. The rule is about what the output can
    /// represent, not about control characters at large.
    private static let forbiddenInPath: CharacterSet = {
        var set = CharacterSet.newlines
        set.insert("\0")
        return set
    }()

    /// The path of one line, when the whole of that line is a remote URL carrying one.
    ///
    /// Rejecting a line with whitespace in it is the whole of "the whole of that line".
    /// `URL(string:)` accepts unescaped spaces — measured, not assumed — so
    /// `sftp://10.0.0.5/home/www is the folder` parses as one URL whose path is
    /// `/home/www is the folder`, and the sentence would be rewritten into a fragment of itself.
    ///
    /// It costs the path a client copied with a literal space in it, which is the right side of
    /// the trade: a client encodes that as `%20`, and the cost of being wrong the other way is a
    /// clipboard silently replaced with something that was never on it.
    private static func path(of line: String) -> String? {
        guard !line.contains(where: { $0.isWhitespace }),
              let url = URL(string: line),
              let scheme = url.scheme,
              schemes.contains(scheme.lowercased())
        else { return nil }

        // Decoded: `%C6%B0` belonged to the URL, and the URL is what is being thrown away. What is
        // left is a path, and a path with a Vietnamese folder name in it should read as one.
        var path = url.path(percentEncoded: false)

        // Absolute, which subsumes non-empty. Two ways this fails:
        //
        // `sftp://host` on its own names no path, so there is nothing to rewrite it to. A bare `/`
        // is not this case: that is the server's root, and a real answer.
        //
        // And a URL without `//` is opaque — `sftp:h/a` has scheme `sftp` and the *relative* path
        // `h/a`. The scheme-prefix early-out only examines the first line, so such a line reaches
        // here whenever it sits in a block behind a well-formed one, and a relative fragment on the
        // clipboard points somewhere else entirely from what was copied. Found by
        // `RemotePathPropertyTests`, not by anybody thinking of it.
        guard path.hasPrefix("/") else { return nil }

        // A client writes the server's own root as a second slash: `sftp://host//home/x` is
        // `/home/x`, the first slash ending the authority and the second beginning the path. The
        // leading run comes back as one.
        //
        // Collapsing rather than deleting the `scheme://host/` prefix, which is the other way to
        // get the same answer for a `//` string: deleting takes the root slash with it whenever the
        // client wrote only one, and `sftp://host/home/x` would come back as the relative
        // `home/x`.
        //
        // Only the leading run. A repeated separator further along is the client's own business —
        // this is not a path normaliser, and `/a/../b` is left alone for the same reason.
        //
        // `drop(while:)` once rather than `removeFirst()` in a loop: the latter is O(n) per call,
        // and a path of nothing but slashes is inside the size bound.
        if path.hasPrefix("//") {
            path = "/" + path.drop(while: { $0 == "/" })
        }

        // `#` and `?` are legal in a POSIX filename, and a client that copies `report#2.txt`
        // unencoded hands over a URL whose "fragment" is really the back half of the name. Taking
        // the path alone would truncate it to `/home/report` — and since the caller then replaces
        // the pasteboard, the rest would be unrecoverable. Put them back in the order a URL writes
        // them. The properly encoded form has neither component, so this does nothing to it.
        if let query = url.query(percentEncoded: false) { path += "?" + query }
        if let fragment = url.fragment(percentEncoded: false) { path += "#" + fragment }

        // Decoding is what makes `%C6%B0` readable, and it will just as happily turn `%0A` into a
        // real newline — measured, from a URL that otherwise looks ordinary. The result of a strip
        // is one path per line, so a path carrying a line break comes back as two, and in a block
        // it is indistinguishable from the neighbouring entries.
        //
        // Scalars, not characters: Swift treats `\r\n` as a single grapheme cluster, so a
        // `Character` comparison against `"\n"` or `"\r"` matches neither and CRLF walks straight
        // through. That is exactly how `%0D%0A` got past the first version of this guard.
        guard !path.unicodeScalars.contains(where: { forbiddenInPath.contains($0) }) else {
            return nil
        }
        return path
    }
}
