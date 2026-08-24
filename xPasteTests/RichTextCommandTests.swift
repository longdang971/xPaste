import XCTest
import AppKit
@testable import xPaste

/// Formatting commands, exercised straight against a text storage.
///
/// No text view and no window anywhere in here — that is the entire reason the commands are a
/// separate type from the toolbar that calls them.
final class RichTextCommandTests: XCTestCase {

    private func storage(_ string: String = "hello world") -> NSTextStorage {
        NSTextStorage(string: string, attributes: ItemEdit.plainDefaults)
    }

    private func font(_ storage: NSTextStorage, at index: Int) -> NSFont {
        (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            ?? ItemEdit.plainFont
    }

    private func isBold(_ font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }

    // MARK: - Traits over a selection

    func test_bold_turns_a_selection_bold() {
        let store = storage()
        _ = RichTextCommand.bold.apply(to: store,
                                       range: NSRange(location: 0, length: 5),
                                       typing: ItemEdit.plainDefaults)
        XCTAssertTrue(isBold(font(store, at: 0)))
        XCTAssertFalse(isBold(font(store, at: 6)))
    }

    /// A toggle is off only when it is on everywhere, so a mixed selection turns fully on rather
    /// than half off — which is what every editor does and what a user expects.
    func test_bold_over_an_already_bold_selection_turns_it_off() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.bold.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.bold.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        XCTAssertFalse(isBold(font(store, at: 0)))
    }

    func test_bold_over_a_partly_bold_selection_turns_all_of_it_bold() {
        let store = storage()
        _ = RichTextCommand.bold.apply(to: store,
                                       range: NSRange(location: 0, length: 2),
                                       typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.bold.apply(to: store,
                                       range: NSRange(location: 0, length: 5),
                                       typing: ItemEdit.plainDefaults)
        XCTAssertTrue(isBold(font(store, at: 0)))
        XCTAssertTrue(isBold(font(store, at: 4)))
    }

    func test_italic_underline_and_strikethrough_each_apply() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.italic.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.underline.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.strikethrough.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        XCTAssertTrue(NSFontManager.shared.traits(of: font(store, at: 0)).contains(.italicFontMask))
        XCTAssertNotEqual(store.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
        XCTAssertNotEqual(store.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, 0)
    }

    // MARK: - Traits with no selection

    /// The single most likely way for the toolbar to feel broken: pressing B with no selection has
    /// to arm the caret, the way TextEdit does, not do nothing.
    func test_bold_with_no_selection_changes_only_the_typing_attributes() {
        let store = storage()
        let typing = RichTextCommand.bold.apply(to: store,
                                                range: NSRange(location: 5, length: 0),
                                                typing: ItemEdit.plainDefaults)
        XCTAssertTrue(isBold((typing[.font] as? NSFont) ?? ItemEdit.plainFont))
        XCTAssertFalse(isBold(font(store, at: 0)), "the storage must be untouched")
    }

    func test_bold_twice_with_no_selection_disarms_the_caret() {
        let store = storage()
        let range = NSRange(location: 5, length: 0)
        let once = RichTextCommand.bold.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        let twice = RichTextCommand.bold.apply(to: store, range: range, typing: once)
        XCTAssertFalse(isBold((twice[.font] as? NSFont) ?? ItemEdit.plainFont))
    }

    // MARK: - Clearing

    func test_clearing_returns_a_selection_to_the_editors_defaults() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.bold.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.underline.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.clearFormatting.apply(to: store, range: range,
                                                  typing: ItemEdit.plainDefaults)
        XCTAssertFalse(ItemEdit.carriesFormatting(store.attributedSubstring(from: range)))
    }

    func test_clearing_leaves_the_text_itself_alone() {
        let store = storage()
        _ = RichTextCommand.clearFormatting.apply(to: store,
                                                  range: NSRange(location: 0, length: store.length),
                                                  typing: ItemEdit.plainDefaults)
        XCTAssertEqual(store.string, "hello world")
    }
}
