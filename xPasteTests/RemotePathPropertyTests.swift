import XCTest
@testable import xPaste

/// Properties that must hold for every input, checked over a generated corpus.
///
/// The enumerated cases in `RemotePathTests` only cover what someone thought to write down, and
/// two rounds of review found things nobody had. These four invariants are what the rest of the
/// system relies on, so anything that violates one is a bug regardless of whether it occurred to
/// anybody: the result is a list of absolute paths, one per line, carrying nothing that a path
/// cannot carry.
///
/// The corpus is generated from a fixed seed, so a failure is reproducible and the suite cannot
/// flake.
final class RemotePathPropertyTests: XCTestCase {

    /// A tiny LCG rather than `SystemRandomNumberGenerator`: the point is that every run examines
    /// the same corpus, so a red test is a red test tomorrow too.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private let schemes = ["sftp", "ftp", "ftps", "SFTP", "FtP", "ssh", "scp", "http", "https", "file", ""]
    private let userinfos = ["", "user@", "user:pass@", "@", "u%40b@"]
    private let hosts = ["h", "10.0.0.5", "[::1]", "", "xn--80ak6aa92e", "H.Example.COM"]
    private let ports = ["", ":22", ":0", ":65535"]
    private let paths = [
        "", "/", "//", "/home/www", "/home/www/", "//home/www", "/a/../b", "/a/./b",
        "/th%C6%B0%20m%E1%BB%A5c", "/My%20Documents", "/report#2.txt", "/what?.txt",
        "/a%0Ab", "/a%0D%0Ab", "/a%00b", "/a%09b", "/a%2Fb", "/a%23b", "/a%3Fb",
        // Everything else `CharacterSet.newlines` treats as a separator: VT, FF, NEL, LS, PS.
        "/a%0Bb", "/a%0Cb", "/a%C2%85b", "/a%E2%80%A8b", "/a%E2%80%A9b",
        "/a b", "/a\tb", "/~/www", "/%2e%2e/etc", "/naïve", "/e̊", "/🙂",
        "/a?q=1", "/a#f", "/a?q=1#f", "/a?", "/a#", "/" + String(repeating: "x", count: 300),
    ]
    private let junk = ["", " ", "\t", "just text", "sftp://", "/already/a/path", "xem sftp://h/a nhe",
                        "sftp:/h/a", "sftp:h/a", "\u{FEFF}sftp://h/a", "  sftp://h/a  "]

    /// One candidate line: usually a URL built from the parts above, sometimes plain junk.
    private func line(_ rng: inout Seeded) -> String {
        if Int.random(in: 0..<4, using: &rng) == 0 { return junk.randomElement(using: &rng)! }
        return schemes.randomElement(using: &rng)!
            + "://"
            + userinfos.randomElement(using: &rng)!
            + hosts.randomElement(using: &rng)!
            + ports.randomElement(using: &rng)!
            + paths.randomElement(using: &rng)!
    }

    /// The lines `strip` will consider, derived the same way it derives them.
    private func significantLines(of text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func testEveryResultIsAListOfAbsolutePaths() {
        var rng = Seeded(state: 0x5eed_1234_5678_9abc)
        var stripped = 0

        // Separators and padding are generated too. `strip` splits on `CharacterSet.newlines`, so
        // CRLF arrives as two separators with an empty line between them, and a lone CR is a
        // separator in its own right — all three have to leave the line count alone.
        let separators = ["\n", "\r\n", "\r", "\n\n", "\n \n"]
        let padding = ["", " ", "\t", "  \n", "\n\t"]

        for _ in 0..<20_000 {
            let count = Int.random(in: 1...4, using: &rng)
            let body = (0..<count)
                .map { _ in line(&rng) }
                .joined(separator: separators.randomElement(using: &rng)!)
            let input = padding.randomElement(using: &rng)! + body + padding.randomElement(using: &rng)!

            guard let result = RemotePath.strip(input) else { continue }
            stripped += 1

            // Split the way `strip` splits its own input, not by LF. `CharacterSet.newlines` is a
            // strictly larger set — VT, FF, NEL, LS, PS — and checking the narrower one is how
            // this invariant used to pass over a path carrying one of them.
            let outLines = result.components(separatedBy: .newlines)

            // 1. Absolute. Everything downstream — the card, the paste, a shell — reads these as
            //    paths, and a relative fragment would point somewhere else entirely.
            for out in outLines {
                XCTAssertTrue(out.hasPrefix("/"),
                              "not absolute: \(out.debugDescription) from \(input.debugDescription)")
            }

            // 2. Nothing a path cannot carry. A CR would split a line downstream just as an LF
            //    does; a NUL would travel into the pasteboard and the store.
            var forbidden = CharacterSet.newlines
            forbidden.remove("\n")   // the separator between paths is legitimate
            forbidden.insert("\0")
            XCTAssertFalse(result.unicodeScalars.contains(where: { forbidden.contains($0) }),
                           "control character in \(result.debugDescription) from \(input.debugDescription)")

            // 3. One path in, one path out. This is what makes a multi-selection paste back as the
            //    same number of entries it was copied as.
            XCTAssertEqual(outLines.count, significantLines(of: input).count,
                           "line count changed: \(input.debugDescription) -> \(result.debugDescription)")

            // 4. The result is a path, not a URL: running it through again finds nothing to do.
            XCTAssertNil(RemotePath.strip(result),
                         "result was itself strippable: \(result.debugDescription)")
        }

        // The corpus has to actually exercise the stripping path, or the invariants above are
        // being checked against nothing.
        XCTAssertGreaterThan(stripped, 1_000, "corpus barely triggered a rewrite")
        print("RemotePath property sweep — 20000 inputs, \(stripped) rewritten")
    }
}
