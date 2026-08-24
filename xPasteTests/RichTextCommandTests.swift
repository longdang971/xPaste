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

    // MARK: - Faces and sizes

    func test_choosing_a_family_keeps_the_size_and_the_traits() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.size(20).apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.bold.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.family("Menlo").apply(to: store, range: range,
                                                  typing: ItemEdit.plainDefaults)
        let got = font(store, at: 0)
        XCTAssertEqual(got.familyName, "Menlo")
        XCTAssertEqual(got.pointSize, 20)
        XCTAssertTrue(isBold(got))
    }

    /// nil means "back to the editor's own face", which is the system font — and it has to keep the
    /// traits, or picking the default family would silently unbold the text.
    func test_a_nil_family_returns_to_the_system_face_without_losing_bold() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.bold.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.family("Menlo").apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.family(nil).apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        let got = font(store, at: 0)
        XCTAssertTrue(RichTextHTML.isSystemFace(got))
        XCTAssertTrue(isBold(got))
    }

    func test_size_changes_the_points_and_keeps_the_face() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.family("Menlo").apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.size(28).apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        XCTAssertEqual(font(store, at: 0).pointSize, 28)
        XCTAssertEqual(font(store, at: 0).familyName, "Menlo")
    }

    /// The system family cannot be looked up by name — `.AppleSystemUIFont` is private — so weights
    /// on it go through `NSFont.systemFont(ofSize:weight:)` instead.
    func test_a_lighter_weight_applies_to_the_system_face() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.weight(.light).apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        let got = font(store, at: 0)
        XCTAssertTrue(RichTextHTML.isSystemFace(got))
        XCTAssertLessThan(NSFontManager.shared.weight(of: got),
                          NSFontManager.shared.weight(of: ItemEdit.plainFont))
    }

    func test_a_lighter_weight_applies_to_a_named_family_too() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.family("Helvetica Neue").apply(to: store, range: range,
                                                           typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.weight(.light).apply(to: store, range: range,
                                                 typing: ItemEdit.plainDefaults)
        XCTAssertEqual(font(store, at: 0).familyName, "Helvetica Neue")
        XCTAssertLessThan(NSFontManager.shared.weight(of: font(store, at: 0)), 5)
    }

    // MARK: - Colours

    func test_a_foreground_colour_applies_and_nil_returns_to_the_default() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.foreground(.systemRed).apply(to: store, range: range,
                                                         typing: ItemEdit.plainDefaults)
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.systemRed)
        _ = RichTextCommand.foreground(nil).apply(to: store, range: range,
                                                  typing: ItemEdit.plainDefaults)
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.labelColor)
    }

    /// A highlight is a light wash and `labelColor` is white in dark mode, so text left dynamic
    /// would vanish into it. The colour is pinned to what it shows in light mode.
    func test_a_highlight_pins_default_coloured_text_so_it_survives_dark_mode() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.background(.systemYellow).apply(to: store, range: range,
                                                            typing: ItemEdit.plainDefaults)
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       RichTextCommand.pinnedBlack)
    }

    func test_a_colour_the_user_chose_is_not_overridden_by_a_highlight() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.foreground(.systemRed).apply(to: store, range: range,
                                                         typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.background(.systemYellow).apply(to: store, range: range,
                                                            typing: ItemEdit.plainDefaults)
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.systemRed)
    }

    func test_removing_a_highlight_releases_the_pinned_colour() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.background(.systemYellow).apply(to: store, range: range,
                                                            typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.background(nil).apply(to: store, range: range,
                                                  typing: ItemEdit.plainDefaults)
        XCTAssertNil(store.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.labelColor)
    }

    // MARK: - Links

    func test_a_link_applies_with_its_own_blue_and_underline() {
        let store = storage()
        let url = URL(string: "https://vidu.com")!
        _ = RichTextCommand.link(url).apply(to: store, range: NSRange(location: 0, length: 5),
                                            typing: ItemEdit.plainDefaults)
        XCTAssertEqual(store.attribute(.link, at: 0, effectiveRange: nil) as? URL, url)
        XCTAssertNotEqual(store.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
    }

    func test_removing_a_link_takes_its_blue_and_underline_with_it() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.link(URL(string: "https://vidu.com")!).apply(to: store, range: range,
                                                                        typing: ItemEdit.plainDefaults)
        _ = RichTextCommand.link(nil).apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        XCTAssertNil(store.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertEqual(store.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
        XCTAssertEqual(store.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       NSColor.labelColor)
    }

    // MARK: - Reading the state back

    func test_the_state_reports_the_traits_under_a_selection() {
        let store = storage()
        let range = NSRange(location: 0, length: 5)
        _ = RichTextCommand.bold.apply(to: store, range: range, typing: ItemEdit.plainDefaults)
        let state = RichTextState.read(from: store, range: range, typing: ItemEdit.plainDefaults)
        XCTAssertTrue(state.bold)
        XCTAssertFalse(state.italic)
    }

    /// A trait shows as on only when it is on throughout, so the button matches what a second press
    /// would do.
    func test_a_partly_bold_selection_does_not_read_as_bold() {
        let store = storage()
        _ = RichTextCommand.bold.apply(to: store, range: NSRange(location: 0, length: 2),
                                       typing: ItemEdit.plainDefaults)
        let state = RichTextState.read(from: store, range: NSRange(location: 0, length: 5),
                                       typing: ItemEdit.plainDefaults)
        XCTAssertFalse(state.bold)
    }

    func test_with_no_selection_the_state_comes_from_the_typing_attributes() {
        let store = storage()
        let armed = RichTextCommand.bold.apply(to: store, range: NSRange(location: 5, length: 0),
                                               typing: ItemEdit.plainDefaults)
        let state = RichTextState.read(from: store, range: NSRange(location: 5, length: 0),
                                       typing: armed)
        XCTAssertTrue(state.bold)
    }

    func test_a_mixed_selection_reports_no_single_size_or_family() {
        let store = storage()
        _ = RichTextCommand.size(20).apply(to: store, range: NSRange(location: 0, length: 2),
                                           typing: ItemEdit.plainDefaults)
        let state = RichTextState.read(from: store, range: NSRange(location: 0, length: 5),
                                       typing: ItemEdit.plainDefaults)
        XCTAssertNil(state.size)
    }

    func test_the_state_reports_the_link_at_the_caret() {
        let store = storage()
        let url = URL(string: "https://vidu.com")!
        _ = RichTextCommand.link(url).apply(to: store, range: NSRange(location: 0, length: 5),
                                            typing: ItemEdit.plainDefaults)
        let state = RichTextState.read(from: store, range: NSRange(location: 2, length: 0),
                                       typing: ItemEdit.plainDefaults)
        XCTAssertEqual(state.link, url)
    }
}
