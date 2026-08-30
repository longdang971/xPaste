import XCTest
@testable import xPaste

final class SearchQueryTests: XCTestCase {

    private func noAppNames(_: String) -> String? { nil }

    func test_plain_query_is_free_text() {
        let q = SearchQuery.parse("hello world")

        XCTAssertTrue(q.types.isEmpty)
        XCTAssertTrue(q.appTerms.isEmpty)
        XCTAssertEqual(q.text, "hello world")
    }

    func test_type_token_filters_and_leaves_no_text() {
        let q = SearchQuery.parse("img:")

        XCTAssertEqual(q.types, [.image])
        XCTAssertEqual(q.text, "")
        XCTAssertFalse(q.isEmpty)
    }

    func test_type_aliases() {
        XCTAssertEqual(SearchQuery.parse("link:").types, [.url])
        XCTAssertEqual(SearchQuery.parse("dir:").types, [.folder])
        XCTAssertEqual(SearchQuery.parse("type:image").types, [.image])
    }

    func test_type_token_combines_with_free_text() {
        let q = SearchQuery.parse("img: invoice")

        XCTAssertEqual(q.types, [.image])
        XCTAssertEqual(q.text, "invoice")
    }

    func test_unknown_token_stays_free_text() {
        let q = SearchQuery.parse("https://x.com/a")

        XCTAssertTrue(q.types.isEmpty)
        XCTAssertEqual(q.text, "https://x.com/a")
    }

    func test_matches_filters_by_type() {
        let q = SearchQuery.parse("img:")
        let image = ClipboardItem(type: .image, imageData: Data([1, 2, 3]))
        let text = ClipboardItem(type: .text, text: "hi")

        XCTAssertTrue(q.matches(image, appName: noAppNames))
        XCTAssertFalse(q.matches(text, appName: noAppNames))
    }

    func test_matches_app_by_bundle_id() {
        let q = SearchQuery.parse("app:chrome")
        let item = ClipboardItem(type: .text, text: "hi", sourceAppBundleID: "com.google.Chrome")

        XCTAssertTrue(q.matches(item, appName: noAppNames))
    }

    func test_matches_app_by_display_name() {
        let q = SearchQuery.parse("app:safari")
        let item = ClipboardItem(type: .text, text: "hi", sourceAppBundleID: "com.apple.WebKit")

        XCTAssertTrue(q.matches(item, appName: { _ in "Safari" }))
    }

    func test_app_filter_excludes_items_without_a_source() {
        let q = SearchQuery.parse("app:chrome")
        let item = ClipboardItem(type: .text, text: "hi")

        XCTAssertFalse(q.matches(item, appName: noAppNames))
    }

    func test_matches_label() {
        let q = SearchQuery.parse("bank")
        let item = ClipboardItem(type: .text, text: "123456789", label: "Bank account")

        XCTAssertTrue(q.matches(item, appName: noAppNames))
    }

    func test_matches_ocr_text() {
        let q = SearchQuery.parse("invoice")
        let item = ClipboardItem(type: .image, imageData: Data([1]), ocrText: "INVOICE 2026")

        XCTAssertTrue(q.matches(item, appName: noAppNames))
    }

    func test_matches_full_file_path_not_only_filename() {
        let q = SearchQuery.parse("Sites")
        let item = ClipboardItem(type: .folder, fileURLs: [URL(fileURLWithPath: "/Users/x/Sites/code")])

        XCTAssertTrue(q.matches(item, appName: noAppNames))
    }

    func test_type_and_app_and_text_are_all_required() {
        let q = SearchQuery.parse("img: app:chrome invoice")
        let match = ClipboardItem(type: .image, imageData: Data([1]),
                                  sourceAppBundleID: "com.google.Chrome", ocrText: "invoice total")
        let wrongApp = ClipboardItem(type: .image, imageData: Data([1]),
                                     sourceAppBundleID: "com.apple.Safari", ocrText: "invoice total")

        XCTAssertTrue(q.matches(match, appName: noAppNames))
        XCTAssertFalse(q.matches(wrongApp, appName: noAppNames))
    }

    func test_empty_query_is_empty() {
        XCTAssertTrue(SearchQuery.parse("   ").isEmpty)
    }
}
