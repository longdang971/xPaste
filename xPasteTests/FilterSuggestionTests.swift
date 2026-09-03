import XCTest
@testable import xPaste

/// What the search box offers while a filter's name is being typed. See `FilterSuggestion`.
final class FilterSuggestionTests: XCTestCase {

    private let apps = [
        FilterSuggestion.App(bundleID: "com.google.Chrome", name: "Google Chrome"),
        FilterSuggestion.App(bundleID: "com.apple.Terminal", name: "Terminal"),
    ]

    private func titles(_ query: String, active: SearchFilters = SearchFilters()) -> [String] {
        FilterSuggestion.matching(query: query, apps: apps, active: active).map(\.title)
    }

    /// The case from the screenshot this was built to match: "to" offers Today.
    func test_a_prefix_offers_the_filters_it_starts() {
        XCTAssertEqual(titles("to"), ["Today"])
    }

    func test_nothing_typed_offers_nothing() {
        XCTAssertEqual(titles(""), [])
        XCTAssertEqual(titles("   "), [])
    }

    func test_a_query_matching_no_filter_offers_nothing() {
        XCTAssertEqual(titles("zzz"), [])
    }

    func test_types_apps_and_dates_are_all_offered() {
        XCTAssertEqual(titles("te"), ["Text", "Terminal"])
        XCTAssertEqual(titles("goo"), ["Google Chrome"])
        XCTAssertEqual(titles("yes"), ["Yesterday"])
    }

    /// A name is matched at the front of any of its words, so the second half of a two-word filter
    /// can be typed on its own.
    func test_a_word_inside_a_name_matches_at_its_start() {
        XCTAssertEqual(titles("chrome"), ["Google Chrome"])
        XCTAssertEqual(titles("week"), ["This week", "Last week"])
    }

    /// Only at the start of a word: matching anywhere would put an unrelated list under the field
    /// on half the keystrokes.
    func test_the_middle_of_a_word_does_not_match() {
        XCTAssertEqual(titles("ext"), [])
        XCTAssertEqual(titles("erminal"), [])
    }

    /// A name that begins with the query beats one that merely has a later word beginning with it.
    func test_a_name_starting_with_the_query_comes_first() {
        XCTAssertEqual(titles("l"), ["Link", "Last week", "Last 30 days"])
    }

    func test_case_and_accents_are_ignored() {
        XCTAssertEqual(titles("TODAY"), ["Today"])
        XCTAssertEqual(titles("téxt"), ["Text"])
    }

    /// The list is what Return would add, so what is already on is not in it.
    func test_filters_already_applied_are_left_out() {
        var active = SearchFilters()
        active.types.insert(.text)
        XCTAssertEqual(titles("te", active: active), ["Terminal"])

        active = SearchFilters()
        active.date = .today
        XCTAssertEqual(titles("to", active: active), [])

        active = SearchFilters()
        active.apps.insert("com.google.Chrome")
        XCTAssertEqual(titles("goo", active: active), [])
    }

    func test_no_more_than_five_are_offered() {
        let many = (0..<20).map { FilterSuggestion.App(bundleID: "app.\($0)", name: "Test \($0)") }
        let found = FilterSuggestion.matching(query: "te", apps: many, active: SearchFilters())
        XCTAssertEqual(found.count, FilterSuggestion.limit)
    }

    /// The row draws the matched part bright, so it has to know where it sits in the name.
    func test_the_matched_part_is_reported_where_it_sits() {
        let today = FilterSuggestion.matching(query: "to", apps: [], active: SearchFilters()).first
        XCTAssertEqual(today?.matchOffset, 0)
        XCTAssertEqual(today?.matchLength, 2)

        let chrome = FilterSuggestion.matching(query: "chro", apps: apps, active: SearchFilters()).first
        XCTAssertEqual(chrome?.title, "Google Chrome")
        XCTAssertEqual(chrome?.matchOffset, 7)
        XCTAssertEqual(chrome?.matchLength, 4)
    }

    func test_picking_a_suggestion_adds_its_filter() {
        var filters = SearchFilters()

        FilterSuggestion.matching(query: "today", apps: [], active: filters).first?.apply(to: &filters)
        XCTAssertEqual(filters.date, .today)

        FilterSuggestion.matching(query: "image", apps: [], active: filters).first?.apply(to: &filters)
        XCTAssertEqual(filters.types, [.image])

        FilterSuggestion.matching(query: "google", apps: apps, active: filters).first?.apply(to: &filters)
        XCTAssertEqual(filters.apps, ["com.google.Chrome"])
    }

    /// Picking a second date replaces the first: `SearchFilters` keeps the date single-choice, and
    /// two windows at once would mean nothing.
    func test_a_second_date_replaces_the_first() {
        var filters = SearchFilters()
        filters.date = .today
        FilterSuggestion.matching(query: "yes", apps: [], active: filters).first?.apply(to: &filters)
        XCTAssertEqual(filters.date, .yesterday)
    }

    func test_apps_come_from_the_items_that_have_one() {
        let items = [
            ClipboardItem(type: .text, text: "a", sourceAppBundleID: "com.apple.Terminal"),
            ClipboardItem(type: .text, text: "b", sourceAppBundleID: "com.google.Chrome"),
            ClipboardItem(type: .text, text: "c", sourceAppBundleID: "com.apple.Terminal"),
            ClipboardItem(type: .text, text: "d", sourceAppBundleID: nil),
        ]
        let found = FilterSuggestion.apps(in: items, name: { $0 == "com.apple.Terminal" ? "Terminal" : "Chrome" })
        XCTAssertEqual(found.map(\.name), ["Chrome", "Terminal"])
    }
}

/// The list the search field publishes and the dropdown draws. See `PanelSuggestions`.
final class PanelSuggestionsTests: XCTestCase {

    private var list: PanelSuggestions { .shared }

    private func rows(_ query: String) -> [FilterSuggestion] {
        FilterSuggestion.matching(query: query, apps: [], active: SearchFilters())
    }

    override func setUp() {
        super.setUp()
        list.clear()
    }

    override func tearDown() {
        list.clear()
        super.tearDown()
    }

    func test_an_empty_list_has_nothing_to_take() {
        XCTAssertNil(list.current)
        XCTAssertTrue(list.rows.isEmpty)
    }

    func test_return_takes_the_first_row_until_the_highlight_moves() {
        list.show(rows("l"))
        XCTAssertEqual(list.current?.title, "Link")
        list.move(by: 1)
        XCTAssertEqual(list.current?.title, "Last week")
    }

    /// The highlight never leaves the list: ↑ at the top and ↓ at the bottom stay put rather than
    /// wrapping, which would take a filter nobody was looking at.
    func test_the_highlight_stops_at_both_ends() {
        list.show(rows("l"))
        list.move(by: -1)
        XCTAssertEqual(list.highlighted, 0)
        list.move(by: 99)
        XCTAssertEqual(list.highlighted, list.rows.count - 1)
    }

    /// A new query starts at the top: the row that was highlighted is rarely still in the list.
    func test_a_new_list_starts_at_the_top() {
        list.show(rows("l"))
        list.move(by: 2)
        list.show(rows("te"))
        XCTAssertEqual(list.highlighted, 0)
    }

    /// Publishing the same rows again — every keystroke that changes nothing — leaves the
    /// highlight where the user put it.
    func test_the_same_rows_again_keep_the_highlight() {
        list.show(rows("l"))
        list.move(by: 1)
        list.show(rows("l"))
        XCTAssertEqual(list.highlighted, 1)
    }
}
