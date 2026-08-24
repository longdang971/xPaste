import XCTest
@testable import xPaste

/// `ColorEditRow.verdict(_:)` in isolation.
///
/// The row itself is a SwiftUI view with no XCTest target reaching it — same shape as
/// `RichTextToolbarTests`' reasoning for testing `RichTextToolbar.familyLabel(for:)` rather than
/// the view around it. What decides what a person reads off this row's contrast reading, though, is
/// a plain ratio-in/verdict-out function, so it is pulled out and tested directly.
final class ColorEditRowTests: XCTestCase {

    func test_below_AA_reads_as_failing() {
        XCTAssertEqual(ColorEditRow.verdict(1), "✕")
        XCTAssertEqual(ColorEditRow.verdict(4.49), "✕")
    }

    /// WCAG's own boundary for normal body text: exactly 4.5:1 passes AA.
    func test_AA_threshold_is_inclusive() {
        XCTAssertEqual(ColorEditRow.verdict(4.5), "AA")
    }

    func test_between_AA_and_AAA_reads_as_AA() {
        XCTAssertEqual(ColorEditRow.verdict(6.99), "AA")
    }

    /// WCAG's own boundary for normal body text: exactly 7:1 passes AAA.
    func test_AAA_threshold_is_inclusive() {
        XCTAssertEqual(ColorEditRow.verdict(7), "AAA")
    }

    func test_above_AAA_still_reads_as_AAA() {
        XCTAssertEqual(ColorEditRow.verdict(21), "AAA")
    }
}
