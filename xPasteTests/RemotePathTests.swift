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
