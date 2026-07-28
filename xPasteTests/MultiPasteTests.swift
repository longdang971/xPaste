import XCTest
@testable import xPaste

final class MultiPasteTests: XCTestCase {

    private func text(_ s: String) -> ClipboardItem { ClipboardItem(type: .text, text: s) }

    func test_joins_selected_text_items_with_newlines() {
        let joined = MultiPaste.joinedText(for: [text("one"), text("two"), text("three")],
                                           separator: .newline)

        XCTAssertEqual(joined, "one\ntwo\nthree")
    }

    func test_keeps_the_given_order() {
        let joined = MultiPaste.joinedText(for: [text("b"), text("a")], separator: .space)

        XCTAssertEqual(joined, "b a")
    }

    func test_space_and_comma_separators() {
        let items = [text("a"), text("b")]

        XCTAssertEqual(MultiPaste.joinedText(for: items, separator: .space), "a b")
        XCTAssertEqual(MultiPaste.joinedText(for: items, separator: .comma), "a, b")
    }

    func test_links_and_files_contribute_their_text_and_paths() {
        let link = ClipboardItem(type: .url, text: "https://example.com")
        let file = ClipboardItem(type: .file, fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])

        let joined = MultiPaste.joinedText(for: [link, file], separator: .newline)

        XCTAssertEqual(joined, "https://example.com\n/tmp/a.txt")
    }

    func test_multi_file_item_lists_every_path() {
        let files = ClipboardItem(type: .file, fileURLs: [URL(fileURLWithPath: "/tmp/a.txt"),
                                                          URL(fileURLWithPath: "/tmp/b.txt")])

        let joined = MultiPaste.joinedText(for: [files, text("x")], separator: .newline)

        XCTAssertEqual(joined, "/tmp/a.txt\n/tmp/b.txt\nx")
    }

    func test_unnamed_image_is_dropped_not_pasted_as_the_word_image() {
        let image = ClipboardItem(type: .image, imageData: Data([1, 2, 3]))

        let joined = MultiPaste.joinedText(for: [text("a"), image, text("b")], separator: .newline)

        XCTAssertEqual(joined, "a\nb")
    }

    func test_named_image_contributes_its_name() {
        let image = ClipboardItem(type: .image, imageData: Data([1]), label: "Logo")

        let joined = MultiPaste.joinedText(for: [text("a"), image], separator: .newline)

        XCTAssertEqual(joined, "a\nLogo")
    }

    func test_single_item_is_not_a_multi_paste() {
        XCTAssertNil(MultiPaste.joinedText(for: [text("only")], separator: .newline))
        XCTAssertNil(MultiPaste.joinedText(for: [], separator: .newline))
    }

    func test_selection_of_two_unnamed_images_falls_back_to_single_paste() {
        let a = ClipboardItem(type: .image, imageData: Data([1]))
        let b = ClipboardItem(type: .image, imageData: Data([2]))

        XCTAssertNil(MultiPaste.joinedText(for: [a, b], separator: .newline))
    }

    func test_stored_separator_defaults_to_newline() {
        let defaults = UserDefaults(suiteName: "xPasteTests.multipaste")!
        defaults.removePersistentDomain(forName: "xPasteTests.multipaste")
        defer { defaults.removePersistentDomain(forName: "xPasteTests.multipaste") }

        XCTAssertEqual(MultiPaste.Separator.stored(defaults), .newline)

        defaults.set("comma", forKey: "multiPasteSeparator")
        XCTAssertEqual(MultiPaste.Separator.stored(defaults), .comma)

        defaults.set("nonsense", forKey: "multiPasteSeparator")
        XCTAssertEqual(MultiPaste.Separator.stored(defaults), .newline)
    }
}
