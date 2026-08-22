import XCTest
@testable import xPaste

/// The comparison behind "is there something newer?". It reads two things written by hand — the
/// Info.plist version and a release's git tag — so the tolerated spellings matter as much as the
/// ordering.
final class SemanticVersionTests: XCTestCase {

    func testOrdersByEachComponentInTurn() {
        XCTAssertTrue(SemanticVersion("1.2.2")! > SemanticVersion("1.2.1")!)
        XCTAssertTrue(SemanticVersion("1.3.0")! > SemanticVersion("1.2.9")!)
        XCTAssertTrue(SemanticVersion("2.0.0")! > SemanticVersion("1.99.99")!)
        XCTAssertFalse(SemanticVersion("1.2.1")! > SemanticVersion("1.2.1")!)
    }

    /// Releases are tagged `v1.2.1` while Info.plist says `1.2.1`. Read differently, every check
    /// would either offer an update that is already installed or never offer one at all.
    func testALeadingVIsOptional() {
        XCTAssertEqual(SemanticVersion("v1.2.1"), SemanticVersion("1.2.1"))
        XCTAssertEqual(SemanticVersion("V1.2.1"), SemanticVersion("1.2.1"))
    }

    /// A tag written short is that release, not an earlier one.
    func testMissingComponentsAreZero() {
        XCTAssertEqual(SemanticVersion("1.2")!.description, "1.2.0")
        XCTAssertEqual(SemanticVersion("2")!.description, "2.0.0")
        XCTAssertTrue(SemanticVersion("1.3")! > SemanticVersion("1.2.9")!)
    }

    func testSurroundingWhitespaceIsIgnored() {
        XCTAssertEqual(SemanticVersion("  1.2.1\n"), SemanticVersion("1.2.1"))
    }

    /// Unreadable is `nil`, never a guess — the caller has to be able to say it could not compare.
    func testRejectsWhatItCannotRead() {
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("v"))
        XCTAssertNil(SemanticVersion("nightly"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion("1..2"))
        XCTAssertNil(SemanticVersion("1.2.x"))
        XCTAssertNil(SemanticVersion("-1.0.0"))
    }
}
