import XCTest
import AppKit
import SwiftUI
@testable import xPaste

/// How many filter tokens keep their labels before the rest collapse behind a counter.
///
/// Seven active filters filled the whole search bar and left the text field a sliver to type in.
final class FilterTokenLayoutTests: XCTestCase {

    /// The seven from the report, in the order they appear.
    private let crowded = ["Text", "Link", "Image", "File", "Folder", "Terminal", "Transmit"]

    func test_a_few_tokens_all_keep_their_labels() {
        XCTAssertEqual(FilterTokenLayout.visibleCount(titles: ["Text", "Link"], budget: 400), 2,
                       "nothing collapses while there is room — the counter is the fallback")
    }

    func test_a_crowded_row_collapses_some_of_them() {
        let visible = FilterTokenLayout.visibleCount(titles: crowded,
                                                     budget: FilterTokenLayout.rowBudget)
        XCTAssertLessThan(visible, crowded.count, "seven tokens must not all stay")
        XCTAssertGreaterThan(visible, 0)
    }

    func test_what_stays_plus_the_counter_actually_fits() {
        // The whole point of the arithmetic: the row it chooses has to fit the budget, counter
        // included. Reserving nothing for the counter would overflow by exactly one chip.
        let budget = FilterTokenLayout.rowBudget
        let visible = FilterTokenLayout.visibleCount(titles: crowded, budget: budget)
        let width = FilterTokenLayout.rowWidth(titles: Array(crowded.prefix(visible)),
                                               withCounter: visible < crowded.count)
        XCTAssertLessThanOrEqual(width, budget)
    }

    func test_a_row_that_fits_exactly_keeps_every_token() {
        let titles = ["Text", "Link", "File"]
        let exact = FilterTokenLayout.rowWidth(titles: titles, withCounter: false)
        XCTAssertEqual(FilterTokenLayout.visibleCount(titles: titles, budget: exact), titles.count,
                       "a row measured to fit must not then be told it does not")
    }

    func test_one_token_survives_a_budget_too_small_even_for_it() {
        // A row of nothing but "+1" names no filter at all, which is worse than overflowing.
        XCTAssertEqual(
            FilterTokenLayout.visibleCount(titles: ["Некоторое очень длинное имя"], budget: 10), 1)
    }

    func test_longer_labels_push_more_behind_the_counter() {
        let short = FilterTokenLayout.visibleCount(titles: ["A", "B", "C", "D", "E"], budget: 220)
        let long = FilterTokenLayout.visibleCount(
            titles: ["Sequel Pro", "Transmit 5", "Visual Studio", "Adobe Photoshop", "IntelliJ"],
            budget: 220)
        XCTAssertGreaterThan(short, long,
                             "the budget is width, not a token count — app names are long")
    }

    func test_no_filters_means_no_tokens() {
        XCTAssertEqual(FilterTokenLayout.visibleCount(titles: [], budget: 220), 0)
    }

    func test_measuring_the_same_title_twice_agrees() {
        // Widths are memoised across toolbar passes; a cache that returned something different the
        // second time would make the row flicker between two layouts.
        XCTAssertEqual(FilterTokenLayout.tokenWidth("Transmit"),
                       FilterTokenLayout.tokenWidth("Transmit"))
    }

    /// The arithmetic above proves the sums. This proves the row actually built from them obeys
    /// the budget — the view could measure correctly and still lay every token out anyway.
    @MainActor
    func test_the_rendered_row_obeys_the_budget() {
        var filters = SearchFilters()
        filters.types = Set(FilterType.allCases)
        filters.apps = ["com.apple.Terminal", "com.panic.Transmit"]

        let host = NSHostingView(rootView: ActiveFilterTokens(filters: .constant(filters)))
        let rendered = host.fittingSize.width

        // Not vacuous: laid out in full, these eight overflow the budget by a wide margin, which is
        // the state the screenshot in the report was showing.
        let unbudgeted = FilterTokenLayout.rowWidth(
            titles: FilterType.allCases.map(\.title) + ["Terminal", "Transmit"],
            withCounter: false)
        XCTAssertGreaterThan(unbudgeted, FilterTokenLayout.rowBudget)

        XCTAssertLessThanOrEqual(rendered, FilterTokenLayout.rowBudget,
                                 "the row rendered \(rendered)pt against a \(FilterTokenLayout.rowBudget)pt budget")
    }

    func test_the_budget_leaves_the_text_field_room_to_type() {
        // The bar is capped at 540pt and shares it with two compact tabs and the filter button.
        XCTAssertLessThan(FilterTokenLayout.rowBudget, 300,
                          "a budget this large would reproduce the very squeeze being fixed")
    }
}
