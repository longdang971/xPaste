import XCTest
import AppKit
@testable import xPaste

/// A colour literal is a content type of its own, decided in the one place that decides type.
final class ColorItemTests: XCTestCase {

    func test_the_notations_the_parser_accepts_are_classified_as_colours() {
        for literal in ["#1e90ff", "#fff", "#1e90ff80", "rgb(30, 144, 255)",
                        "rgba(30, 144, 255, 0.5)", "hsl(210, 100%, 56%)"] {
            XCTAssertEqual(ClipboardItem.contentType(for: literal), .color, literal)
        }
    }

    /// Prose that merely mentions a colour is prose. `ColorParser` decides this, and it anchors its
    /// patterns for exactly this reason — the test is here to keep the type honest about deferring.
    func test_prose_mentioning_a_colour_stays_text() {
        for text in ["the background is #1e90ff", "#1e90ff is nice", "hello", "#zzzzzz"] {
            XCTAssertEqual(ClipboardItem.contentType(for: text), .text, text)
        }
    }

    func test_a_link_is_still_a_link() {
        XCTAssertEqual(ClipboardItem.contentType(for: "https://example.com"), .url)
    }

    /// Capture and editing must not be able to disagree: both ask `contentType(for:)`.
    func test_editing_a_colour_into_prose_reclassifies_it_and_back_again() {
        XCTAssertEqual(ClipboardItem.contentType(for: "#1e90ff"), .color)
        XCTAssertEqual(ClipboardItem.contentType(for: "not a colour any more"), .text)
        XCTAssertEqual(ClipboardItem.contentType(for: "rgb(1, 2, 3)"), .color)
    }

    // MARK: - What the editor may do with one

    func test_a_colour_is_editable() {
        XCTAssertTrue(ItemEdit.canEdit(.color))
    }

    /// A seven-character hex code has no business carrying an RTF document.
    func test_a_colour_never_keeps_formatting() {
        let colour = ClipboardItem(type: .color, text: "#1e90ff")
        XCTAssertFalse(ItemEdit.keepsFormatting(colour))
        XCTAssertFalse(ItemEdit.editorSeed(for: colour, parsed: nil).formatted)
    }

    func test_a_colour_item_pastes_its_text() {
        let pb = NSPasteboard(name: .init("colour-test"))
        ClipboardItem(type: .color, text: "#1e90ff").write(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "#1e90ff")
    }

    // MARK: - Migration

    /// Every colour ever copied is on disk as `"type": "text"`. Without this there would be two
    /// classes of colour item: old ones the editor still treats as prose, new ones it does not.
    func test_a_colour_stored_as_text_loads_as_a_colour() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorMigration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seed = ClipboardStore(maxItems: 50, storageDir: dir)
        seed.add(ClipboardItem(type: .text, text: "#1e90ff"))
        seed.add(ClipboardItem(type: .text, text: "just prose"))
        seed.flushPendingWrites()

        let reopened = ClipboardStore(maxItems: 50, storageDir: dir)
        let colour = try XCTUnwrap(reopened.items.first { $0.text == "#1e90ff" })
        let prose = try XCTUnwrap(reopened.items.first { $0.text == "just prose" })
        XCTAssertEqual(colour.type, .color, "the stored colour was not reclassified")
        XCTAssertEqual(prose.type, .text)
    }
}
