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

    // MARK: - Rebasing onto a row that changed underneath

    /// Switching tab, typing a search term, adding a filter token and folding the search box away
    /// all swap the visible row out from under the selection. An id that is no longer on screen
    /// highlights nothing, so the panel sat with nothing selected and ⏎ / Backspace did nothing
    /// until the user reached for the mouse.

    func test_a_selection_still_on_screen_is_left_alone() {
        XCTAssertNil(PanelSelection.rebased(in: items, selected: [items[3]]),
                     "nil means don't touch it — re-selecting would jump the highlight to the front")
    }

    func test_a_selection_that_scrolled_out_of_the_results_moves_to_the_first() {
        let results = [items[2], items[4]]
        XCTAssertEqual(PanelSelection.rebased(in: results, selected: [items[0]]), [items[2]])
    }

    func test_an_empty_selection_takes_the_first_card() {
        XCTAssertEqual(PanelSelection.rebased(in: items, selected: []), [items[0]])
    }

    func test_a_partly_surviving_multi_selection_is_kept_whole() {
        // Two cards ⌘-clicked, one of them filtered out: collapsing to a single card here would
        // silently drop the other from a batch paste the user had already lined up.
        XCTAssertNil(PanelSelection.rebased(in: [items[1]], selected: [items[1], items[4]]))
    }

    func test_a_row_with_no_results_selects_nothing() {
        XCTAssertEqual(PanelSelection.rebased(in: [], selected: [items[0]]), Set<UUID>())
    }

    // MARK: - Collapsing on a click into empty space

    /// That click is meant to drop a multi-selection back to one card. It used to drop to none,
    /// and because it runs a runloop tick late it also wiped whatever the tab switch or the
    /// closing search box had just put back.

    func test_a_multi_selection_collapses_onto_its_topmost_card() {
        XCTAssertEqual(PanelSelection.collapsed(in: items, selected: [items[3], items[1]]),
                       [items[1]], "the one nearest the front of the row survives, not any of them")
    }

    func test_a_single_selection_is_left_where_it_is() {
        XCTAssertEqual(PanelSelection.collapsed(in: items, selected: [items[3]]), [items[3]],
                       "collapsing must not jerk the highlight back to the front of the row")
    }

    func test_collapsing_with_nothing_selected_takes_the_first_card() {
        XCTAssertEqual(PanelSelection.collapsed(in: items, selected: []), [items[0]])
    }

    func test_collapsing_an_empty_row_selects_nothing() {
        XCTAssertEqual(PanelSelection.collapsed(in: [], selected: [items[0]]), Set<UUID>())
    }
}
