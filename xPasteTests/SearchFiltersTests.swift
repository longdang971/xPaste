import XCTest
@testable import xPaste

final class SearchFiltersTests: XCTestCase {

    private let calendar = Calendar.current
    private let now = Date()

    private func item(_ type: ClipboardContentType,
                      text: String? = nil,
                      app: String? = nil,
                      at date: Date? = nil) -> ClipboardItem {
        ClipboardItem(type: type, text: text, imageData: type == .image ? Data([1]) : nil,
                      timestamp: date ?? now, sourceAppBundleID: app)
    }

    func test_empty_filters_match_everything() {
        let filters = SearchFilters()

        XCTAssertTrue(filters.isEmpty)
        XCTAssertTrue(filters.matches(item(.text, text: "hi"), now: now, calendar: calendar))
    }

    func test_type_filter_matches_only_that_type() {
        var filters = SearchFilters()
        filters.toggle(.image)

        XCTAssertTrue(filters.matches(item(.image), now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.text, text: "hi"), now: now, calendar: calendar))
    }

    func test_types_are_or_ed_together() {
        var filters = SearchFilters()
        filters.toggle(.image)
        filters.toggle(.link)

        XCTAssertTrue(filters.matches(item(.image), now: now, calendar: calendar))
        XCTAssertTrue(filters.matches(item(.url, text: "https://x.com"), now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.text, text: "hi"), now: now, calendar: calendar))
    }

    func test_color_and_text_are_distinct_types() {
        var colorOnly = SearchFilters()
        colorOnly.toggle(.color)
        var textOnly = SearchFilters()
        textOnly.toggle(.text)

        let color = item(.text, text: "#1e90ff")
        let prose = item(.text, text: "hello")

        XCTAssertTrue(colorOnly.matches(color, now: now, calendar: calendar))
        XCTAssertFalse(colorOnly.matches(prose, now: now, calendar: calendar))
        XCTAssertTrue(textOnly.matches(prose, now: now, calendar: calendar))
        XCTAssertFalse(textOnly.matches(color, now: now, calendar: calendar))
    }

    func test_app_filter() {
        var filters = SearchFilters()
        filters.toggle(app: "com.google.Chrome")

        XCTAssertTrue(filters.matches(item(.text, text: "a", app: "com.google.Chrome"),
                                      now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.text, text: "a", app: "com.apple.Terminal"),
                                       now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.text, text: "a"), now: now, calendar: calendar))
    }

    func test_sections_are_and_ed_together() {
        var filters = SearchFilters()
        filters.toggle(.image)
        filters.toggle(app: "com.google.Chrome")

        XCTAssertTrue(filters.matches(item(.image, app: "com.google.Chrome"),
                                      now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.image, app: "com.apple.Terminal"),
                                       now: now, calendar: calendar))
    }

    func test_today_filter() {
        var filters = SearchFilters()
        filters.toggle(date: .today)
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!

        XCTAssertTrue(filters.matches(item(.text, text: "now"), now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.text, text: "old", at: twoDaysAgo),
                                       now: now, calendar: calendar))
    }

    func test_yesterday_filter_excludes_today() {
        var filters = SearchFilters()
        filters.toggle(date: .yesterday)
        let yesterdayNoon = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
            .addingTimeInterval(12 * 3600)

        XCTAssertTrue(filters.matches(item(.text, text: "y", at: yesterdayNoon),
                                      now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.text, text: "t"), now: now, calendar: calendar))
    }

    func test_last30Days_filter() {
        var filters = SearchFilters()
        filters.toggle(date: .last30Days)
        let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!
        let yearAgo = calendar.date(byAdding: .day, value: -365, to: now)!

        XCTAssertTrue(filters.matches(item(.text, text: "recent", at: tenDaysAgo),
                                      now: now, calendar: calendar))
        XCTAssertFalse(filters.matches(item(.text, text: "ancient", at: yearAgo),
                                       now: now, calendar: calendar))
    }

    func test_date_is_single_choice() {
        var filters = SearchFilters()
        filters.toggle(date: .today)
        filters.toggle(date: .yesterday)

        XCTAssertEqual(filters.date, .yesterday)

        filters.toggle(date: .yesterday)
        XCTAssertNil(filters.date)
    }

    func test_toggle_off_removes_selection() {
        var filters = SearchFilters()
        filters.toggle(.image)
        filters.toggle(.image)

        XCTAssertTrue(filters.types.isEmpty)
        XCTAssertTrue(filters.isEmpty)
    }

    func test_removeLastToken_drops_the_date_first() {
        var filters = SearchFilters()
        filters.toggle(.image)
        filters.toggle(app: "com.google.Chrome")
        filters.toggle(date: .today)

        filters.removeLastToken(appName: { _ in nil })

        XCTAssertNil(filters.date)
        XCTAssertEqual(filters.apps, ["com.google.Chrome"])
        XCTAssertEqual(filters.types, [.image])
    }

    func test_removeLastToken_then_drops_the_last_app_by_display_name() {
        var filters = SearchFilters()
        filters.toggle(.image)
        filters.toggle(app: "com.a.first")   // "Alpha"
        filters.toggle(app: "com.z.second")  // "Zulu" — last on screen

        filters.removeLastToken(appName: { $0 == "com.a.first" ? "Alpha" : "Zulu" })

        XCTAssertEqual(filters.apps, ["com.a.first"])
        XCTAssertEqual(filters.types, [.image])
    }

    func test_removeLastToken_finally_drops_the_last_type() {
        var filters = SearchFilters()
        filters.toggle(.text)     // drawn first
        filters.toggle(.folder)   // drawn last

        filters.removeLastToken(appName: { _ in nil })

        XCTAssertEqual(filters.types, [.text])
    }

    func test_removeLastToken_on_empty_filters_does_nothing() {
        var filters = SearchFilters()

        filters.removeLastToken(appName: { _ in nil })

        XCTAssertTrue(filters.isEmpty)
    }

    func test_repeated_removeLastToken_empties_everything() {
        var filters = SearchFilters()
        filters.toggle(.image)
        filters.toggle(.link)
        filters.toggle(app: "com.google.Chrome")
        filters.toggle(date: .today)

        for _ in 0..<4 { filters.removeLastToken(appName: { _ in nil }) }

        XCTAssertTrue(filters.isEmpty)
    }

    func test_clear_resets_every_section() {
        var filters = SearchFilters()
        filters.toggle(.image)
        filters.toggle(app: "com.google.Chrome")
        filters.toggle(date: .today)
        XCTAssertEqual(filters.activeCount, 3)

        filters.clear()

        XCTAssertTrue(filters.isEmpty)
    }
}
