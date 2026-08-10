import XCTest
@testable import xPaste

/// The arithmetic behind "select what was just pasted".
///
/// Separated from the Accessibility calls because this is where a wrong answer does damage: a
/// negative or over-long range handed to another application selects the wrong text, or is rejected
/// outright and the highlight silently never appears.
final class AXTextSelectionTests: XCTestCase {

    func testTheRangeWalksBackFromTheCaretByTheLengthInserted() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 20, length: 5)
        XCTAssertEqual(r.location, 15)
        XCTAssertEqual(r.length, 5)
    }

    /// The caret can sit earlier than the insertion is long — the target may have normalised
    /// newlines away, or accepted only part of the paste. Clamp rather than hand back a negative
    /// location.
    func testACaretShorterThanTheInsertionClampsToTheStart() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 3, length: 10)
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 3)
    }

    func testACaretAtTheStartSelectsNothing() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 0, length: 4)
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 0)
    }

    func testNothingInsertedSelectsNothing() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 12, length: 0)
        XCTAssertEqual(r.location, 12)
        XCTAssertEqual(r.length, 0)
    }
}
