import XCTest
@testable import xPaste

/// What the app makes of GitHub's answer. The lenient parts are the point: a release can be
/// published with no notes and nothing attached, and that has to read as "nothing to install"
/// rather than as a broken server.
final class ReleaseInfoTests: XCTestCase {

    private func decode(_ json: String) throws -> ReleaseInfo {
        try ReleaseInfo.decode(from: Data(json.utf8))
    }

    func testReadsTagNotesAndAssets() throws {
        let release = try decode("""
        {"tag_name":"v1.3.0","body":"## What's New\\n- Faster","assets":[
          {"name":"xPaste-1.3.0.zip","browser_download_url":"https://github.com/a/b/x.zip","size":2548260}
        ]}
        """)
        XCTAssertEqual(release.tagName, "v1.3.0")
        XCTAssertEqual(release.body, "## What's New\n- Faster")
        XCTAssertEqual(release.appArchive?.name, "xPaste-1.3.0.zip")
        XCTAssertEqual(release.appArchive?.size, 2_548_260)
    }

    func testMissingOrNullNotesReadAsEmpty() throws {
        XCTAssertEqual(try decode(#"{"tag_name":"v1.3.0","assets":[]}"#).body, "")
        XCTAssertEqual(try decode(#"{"tag_name":"v1.3.0","body":null,"assets":[]}"#).body, "")
    }

    /// A release with nothing attached yet: no archive, but still a readable release.
    func testAReleaseWithNoAssetsHasNoArchive() throws {
        let release = try decode(#"{"tag_name":"v1.3.0","assets":[]}"#)
        XCTAssertNil(release.appArchive)
    }

    func testIgnoresAttachmentsThatAreNotAnApp() throws {
        let release = try decode("""
        {"tag_name":"v1.3.0","assets":[
          {"name":"notes.txt","browser_download_url":"https://github.com/a/b/n.txt","size":10},
          {"name":"xPaste-1.3.0.zip","browser_download_url":"https://github.com/a/b/x.zip","size":99}
        ]}
        """)
        XCTAssertEqual(release.appArchive?.name, "xPaste-1.3.0.zip")
    }

    /// A `.dmg` still installs, so changing how a release is packaged does not strand anyone
    /// already running an older build.
    func testAcceptsADiskImageToo() throws {
        let release = try decode("""
        {"tag_name":"v1.3.0","assets":[
          {"name":"xPaste-1.3.0.dmg","browser_download_url":"https://github.com/a/b/x.dmg","size":99}
        ]}
        """)
        XCTAssertEqual(release.appArchive?.name, "xPaste-1.3.0.dmg")
    }

    /// Without a tag there is no version to compare, so this one really is a failure.
    func testAReleaseWithNoTagIsAnError() {
        XCTAssertThrowsError(try decode(#"{"body":"hi","assets":[]}"#))
    }
}
