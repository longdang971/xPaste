import XCTest
@testable import xPaste

/// The rule table from `docs/superpowers/specs/2026-09-06-remote-path-strip-design.md`.
///
/// Pure string→string, so none of this needs a pasteboard or a running app — which is the reason
/// `RemotePath` holds no AppKit.
final class RemotePathTests: XCTestCase {

    // MARK: - What gets stripped

    func testAServerPathLosesItsScheme() {
        XCTAssertEqual(RemotePath.strip("sftp://10.0.0.5/home/www"), "/home/www")
    }

    /// The user and the port belong to the authority, not the path. `user@` in particular is a
    /// credential nobody means to paste into a shared config.
    func testTheUserAndPortGoWithTheHost() {
        XCTAssertEqual(RemotePath.strip("sftp://pikalong@10.0.0.5:2222/home/www"), "/home/www")
    }

    func testTheSchemeIsMatchedWithoutRegardToCase() {
        XCTAssertEqual(RemotePath.strip("SFTP://Host/Path"), "/Path")
    }

    func testPlainAndSecureFTPAreStrippedToo() {
        XCTAssertEqual(RemotePath.strip("ftp://h/a"), "/a")
        XCTAssertEqual(RemotePath.strip("ftps://h/a"), "/a")
    }

    /// The encoding belonged to the URL, and the URL is what is being thrown away. A Vietnamese
    /// folder name comes back readable rather than as `%C6%B0`.
    func testPercentEncodingIsDecoded() {
        XCTAssertEqual(RemotePath.strip("sftp://h/th%C6%B0%20m%E1%BB%A5c"), "/thư mục")
    }

    /// The server's root is a real answer, not an empty one.
    func testATrailingSlashStripsToRoot() {
        XCTAssertEqual(RemotePath.strip("sftp://10.0.0.5/"), "/")
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(RemotePath.strip("  sftp://h/a\n"), "/a")
    }

    // MARK: - What is left alone

    /// No path means nothing to rewrite it to.
    func testAHostWithNoPathIsLeftAlone() {
        XCTAssertNil(RemotePath.strip("sftp://10.0.0.5"))
    }

    /// Shell targets rather than things a file browser copies.
    func testSSHAndSCPAreNotStripped() {
        XCTAssertNil(RemotePath.strip("ssh://h/a"))
        XCTAssertNil(RemotePath.strip("scp://h/a"))
    }

    /// These two are the schemes `ClipboardItem.contentType` promotes to a Link card; stripping one
    /// would leave that card showing a meaningless fragment.
    func testWebURLsAreNotStripped() {
        XCTAssertNil(RemotePath.strip("http://h/a"))
        XCTAssertNil(RemotePath.strip("https://h/a"))
    }

    /// Prose that mentions a URL is prose. Rewriting it into a fragment of itself would be
    /// destroying what was copied.
    func testAURLInsideASentenceIsNotStripped() {
        XCTAssertNil(RemotePath.strip("Xem sftp://h/a nhé"))
    }

    func testSomethingThatIsAlreadyAPathIsLeftAlone() {
        XCTAssertNil(RemotePath.strip("/home/www"))
    }

    func testEmptyTextIsLeftAlone() {
        XCTAssertNil(RemotePath.strip(""))
        XCTAssertNil(RemotePath.strip("   \n  "))
    }

    // MARK: - Several at once

    /// Selecting three folders and copying gives one URL per line.
    func testEveryLineOfAllRemoteURLsIsStripped() {
        let copied = """
        sftp://10.0.0.5/home/www
        sftp://10.0.0.5/var/log
        ftp://10.0.0.5/tmp
        """
        XCTAssertEqual(RemotePath.strip(copied), "/home/www\n/var/log\n/tmp")
    }

    /// A partial rewrite would leave a list where some entries had lost their host and others had
    /// not — worse than either outcome, so one bad line disowns the block.
    func testOneLineThatIsNotARemoteURLDisownsTheWholeBlock() {
        let copied = """
        sftp://10.0.0.5/home/www
        just some text
        sftp://10.0.0.5/var/log
        """
        XCTAssertNil(RemotePath.strip(copied))
    }

    /// A host with no path is exactly as disqualifying inside a block as it is on its own.
    func testABlockContainingAPathlessHostIsLeftAlone() {
        XCTAssertNil(RemotePath.strip("sftp://10.0.0.5/home/www\nsftp://10.0.0.5"))
    }

    func testBlankLinesBetweenURLsDoNotDisownTheBlock() {
        XCTAssertEqual(RemotePath.strip("sftp://h/a\n\nsftp://h/b"), "/a\n/b")
    }
}

// MARK: - Bounds

extension RemotePathTests {

    /// Past `sizeLimit`, whatever was copied is something other than a path list.
    func testAnImplausiblyLargeBlockIsLeftAlone() {
        let huge = String(repeating: "sftp://10.0.0.5/home/www\n", count: 20_000)
        XCTAssertGreaterThan(huge.utf8.count, 256 * 1024)
        XCTAssertNil(RemotePath.strip(huge))
    }

    /// …but a block big enough to be a real multi-selection still goes through, so the bound is
    /// not quietly rejecting the case the feature exists for.
    func testALargeButPlausibleBlockOfPathsIsStillStripped() {
        let block = (0..<1_000).map { "sftp://10.0.0.5/home/dir\($0)" }.joined(separator: "\n")
        let stripped = RemotePath.strip(block)
        XCTAssertEqual(stripped?.components(separatedBy: "\n").count, 1_000)
        XCTAssertEqual(stripped?.hasPrefix("/home/dir0\n/home/dir1\n"), true)
    }
}

// MARK: - Prose that begins with a URL

extension RemotePathTests {

    /// `URL(string:)` accepts unescaped spaces, so a sentence whose *first* word happens to be a
    /// remote URL parses as one URL with a very long path — and the whole sentence would be
    /// rewritten into a fragment of itself. A copied URL has no bare spaces in it; `%20` is what a
    /// real one carries.
    func testASentenceBeginningWithARemoteURLIsNotStripped() {
        XCTAssertNil(RemotePath.strip("sftp://10.0.0.5/home/www is the folder"))
        XCTAssertNil(RemotePath.strip("sftp://h/a and then some more words"))
    }

    /// The same rule inside a block: one line carrying prose disowns all of it.
    func testALineOfProseBeginningWithAURLDisownsTheBlock() {
        XCTAssertNil(RemotePath.strip("sftp://h/a\nsftp://h/b is the one"))
    }

    /// And the encoded form still works, which is what a client actually copies.
    func testAnEncodedSpaceIsStillAPath() {
        XCTAssertEqual(RemotePath.strip("sftp://h/My%20Documents"), "/My Documents")
    }
}

// MARK: - Filenames that look like URL syntax

/// `#` and `?` are legal in a POSIX filename, and a client that copies one unencoded hands over a
/// URL whose "fragment" and "query" are really part of the path.
extension RemotePathTests {

    func testAHashInAFilenameSurvives() {
        XCTAssertEqual(RemotePath.strip("sftp://h/home/report#2.txt"), "/home/report#2.txt")
    }

    func testAQuestionMarkInAFilenameSurvives() {
        XCTAssertEqual(RemotePath.strip("sftp://h/notes/what?.txt"), "/notes/what?.txt")
    }

    /// Reassembled in the order a URL puts them, so the path comes back as it was written.
    func testAQuestionMarkAndAHashTogetherKeepTheirOrder() {
        XCTAssertEqual(RemotePath.strip("sftp://h/a?q=1#f"), "/a?q=1#f")
    }

    /// The properly encoded form was never broken, and must not become double-handled.
    func testAnEncodedHashIsUnaffected() {
        XCTAssertEqual(RemotePath.strip("sftp://h/home/report%232.txt"), "/home/report#2.txt")
    }
}

// MARK: - Encodings that decode into something a path cannot carry

/// Percent-decoding is what makes `%C6%B0` readable, but it will just as happily produce a control
/// character. The result is one path per line, so a decoded newline would come back as two paths.
extension RemotePathTests {

    func testAnEncodedNewlineDisownsTheLine() {
        XCTAssertNil(RemotePath.strip("sftp://h/a%0Ab"))
        XCTAssertNil(RemotePath.strip("sftp://h/a%0D%0Ab"))
    }

    /// And it takes the block with it, the way any unusable line does.
    func testAnEncodedNewlineDisownsTheWholeBlock() {
        XCTAssertNil(RemotePath.strip("sftp://h/good\nsftp://h/a%0Ab"))
    }

    /// No POSIX path may contain a NUL, and it would travel into the pasteboard and the store as a
    /// string nothing downstream expects.
    func testAnEncodedNulDisownsTheLine() {
        XCTAssertNil(RemotePath.strip("sftp://h/a%00b"))
    }

    /// A tab is not a line break and does not break the contract, so it is left to come through —
    /// this is here to say the rule is about the contract, not about control characters at large.
    func testAnEncodedTabIsStillAPath() {
        XCTAssertEqual(RemotePath.strip("sftp://h/a%09b"), "/a\tb")
    }
}

// MARK: - The result has to be an absolute path

/// A URL without `//` is opaque: `sftp:h/a` has scheme `sftp` and path `h/a`, which is relative.
/// The scheme-prefix early-out only examines the first line, so such a line reaches the parser
/// whenever it sits in a block behind a well-formed one — and a relative fragment on the clipboard
/// points somewhere else entirely from the path that was copied.
extension RemotePathTests {

    func testAnOpaqueURLIsNotAPath() {
        XCTAssertNil(RemotePath.strip("sftp:h/a"))
    }

    func testAnOpaqueURLBehindAWellFormedOneDisownsTheBlock() {
        XCTAssertNil(RemotePath.strip("sftp://h/home/www\nsftp:h/a"))
    }

    /// The authority-less absolute form still names an absolute path, and is kept.
    func testAnAuthoritylessAbsolutePathIsStillAPath() {
        XCTAssertEqual(RemotePath.strip("sftp:///home/www"), "/home/www")
    }
}

/// `hasPrefix("/")` compares grapheme clusters, and a combining mark immediately after the slash
/// forms one cluster with it. So `%CC%88` decodes to a path whose first *scalar* is `/` while its
/// first *character* is not, and the guard refuses it.
///
/// That is the safe direction — nothing is written, the copy is left as it was — and it is pinned
/// here deliberately: rewriting the guard as a scalar comparison, which reads like a tidy-up after
/// the CRLF lesson elsewhere in this file, would quietly let it through instead.
extension RemotePathTests {

    func testAPathWhoseSlashIsAbsorbedByACombiningMarkIsRefused() {
        let decoded = URL(string: "sftp://h/%CC%88a")?.path(percentEncoded: false)
        XCTAssertEqual(decoded?.unicodeScalars.first, "/", "premise: the first scalar really is a slash")
        XCTAssertNotEqual(decoded?.first, "/", "premise: the first character really is not")

        XCTAssertNil(RemotePath.strip("sftp://h/%CC%88a"))
    }
}

// MARK: - Every character the splitter treats as a line break

/// `strip` splits its input with `components(separatedBy: .newlines)`, which is a strictly larger
/// set than LF and CR: it also contains VT, FF, NEL, LS and PS. A decoded path carrying any of them
/// comes back as two lines from the same splitter, which is the exact failure the guard exists to
/// prevent — so the guard has to be derived from that set rather than list members by hand.
extension RemotePathTests {

    func testEveryEncodedNewlineTheSplitterKnowsDisownsTheLine() {
        for encoded in ["%0A", "%0D", "%0B", "%0C", "%C2%85", "%E2%80%A8", "%E2%80%A9"] {
            XCTAssertNil(RemotePath.strip("sftp://h/a\(encoded)b"),
                         "\(encoded) decoded into something the splitter treats as a line break")
        }
    }

    func testOneOfThemInABlockDisownsTheWholeBlock() {
        XCTAssertNil(RemotePath.strip("sftp://h/good\nsftp://h/a%E2%80%A8b"))
    }
}

// MARK: - How far the scheme may sit behind whitespace

/// The search for the first non-whitespace character runs before the size bound, so it is bounded
/// itself. These pin where the boundary falls.
extension RemotePathTests {

    func testAPathBehindTheFullAllowanceOfWhitespaceIsStillStripped() {
        let padded = String(repeating: " ", count: 32) + "sftp://h/a"
        XCTAssertEqual(RemotePath.strip(padded), "/a")
    }

    /// Past it, refused — the safe direction, since nothing is written. No copied path arrives
    /// behind thirty-odd spaces.
    func testAPathBehindMoreWhitespaceThanThatIsRefused() {
        let padded = String(repeating: " ", count: 40) + "sftp://h/a"
        XCTAssertNil(RemotePath.strip(padded))
    }
}
