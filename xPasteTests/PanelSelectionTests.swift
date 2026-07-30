import XCTest
@testable import xPaste

/// The rule for what stays selected after a delete.
///
/// Backspace used to clear the selection outright, so deleting a run of items meant reaching for
/// the mouse between every single one: the second press had nothing to act on.
final class PanelSelectionTests: XCTestCase {

    private var items: [UUID] = []

    override func setUp() {
        super.setUp()
        items = (0..<5).map { _ in UUID() }
    }

    private func survivor(deleting indices: [Int]) -> UUID? {
        PanelSelection.survivor(in: items, deleting: Set(indices.map { items[$0] }))
    }

    func test_the_card_that_slides_into_the_gap_takes_the_selection() {
        XCTAssertEqual(survivor(deleting: [2]), items[3])
    }

    func test_deleting_the_first_card_selects_the_new_first() {
        XCTAssertEqual(survivor(deleting: [0]), items[1])
    }

    func test_deleting_the_last_card_falls_back_to_the_one_before_it() {
        // Nothing slides into the gap at the end of the row, so the selection walks backwards
        // instead of being dropped.
        XCTAssertEqual(survivor(deleting: [4]), items[3])
    }

    func test_a_deleted_block_skips_to_the_first_survivor_past_it() {
        XCTAssertEqual(survivor(deleting: [1, 2, 3]), items[4])
    }

    func test_a_block_running_to_the_end_falls_back_before_it() {
        XCTAssertEqual(survivor(deleting: [2, 3, 4]), items[1])
    }

    func test_a_scattered_selection_still_lands_on_a_survivor() {
        // ⌘-clicked cards need not be adjacent; index 1 is the first survivor after index 0.
        XCTAssertEqual(survivor(deleting: [0, 2, 4]), items[1])
    }

    func test_deleting_everything_leaves_nothing_selected() {
        XCTAssertNil(survivor(deleting: [0, 1, 2, 3, 4]))
    }

    func test_deleting_nothing_selects_nothing() {
        XCTAssertNil(PanelSelection.survivor(in: items, deleting: []))
    }

    func test_an_id_that_is_no_longer_on_screen_selects_nothing() {
        // The card was filtered out from under the selection, or already gone.
        XCTAssertNil(PanelSelection.survivor(in: items, deleting: [UUID()]))
    }

    func test_an_empty_list_selects_nothing() {
        XCTAssertNil(PanelSelection.survivor(in: [], deleting: [items[0]]))
    }
}
