import XCTest
import AppKit
@testable import xPaste

/// The editor's mode and seed.
///
/// A real `NSTextView` is used and never put in a window — that is enough for the buffer to read
/// from, and it keeps the whole of the mode logic out of a UI test.
///
/// `@MainActor` because `EditSession` is: it owns a text view, so it has nowhere else to live.
@MainActor
final class EditSessionTests: XCTestCase {

    private func session(_ seed: NSAttributedString) -> (EditSession, NSTextView) {
        let session = EditSession()
        session.begin(with: seed)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.isRichText = true
        view.textStorage?.setAttributedString(seed)
        session.buffer.textView = view
        return (session, view)
    }

    private func bolded(_ string: String) -> NSAttributedString {
        let bold = NSFontManager.shared.convert(ItemEdit.plainFont, toHaveTrait: .boldFontMask)
        let text = NSMutableAttributedString(string: string, attributes: ItemEdit.plainDefaults)
        text.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 2))
        return text
    }

    func test_a_session_begins_formatted() {
        let (session, _) = session(NSAttributedString(string: "hi", attributes: ItemEdit.plainDefaults))
        XCTAssertEqual(session.mode, .formatted)
        XCTAssertEqual(session.seed.string, "hi")
    }

    func test_switching_to_raw_seeds_the_markup() {
        let (session, _) = session(bolded("hi there"))
        session.toggleMode()
        XCTAssertEqual(session.mode, .raw)
        XCTAssertEqual(session.seed.string, "<p><b>hi</b> there</p>")
    }

    /// The view is rebuilt rather than written into, so the generation has to move or SwiftUI keeps
    /// the old text view and the seed never lands.
    func test_every_switch_bumps_the_generation() {
        let (session, view) = session(bolded("hi there"))
        let before = session.generation
        session.toggleMode()
        view.string = session.seed.string
        session.toggleMode()
        XCTAssertEqual(session.generation, before + 2)
    }

    /// Every conversion costs a little fidelity. Nobody should pay it for a mis-click, so an
    /// untouched round trip hands back the very object it started with.
    func test_switching_back_untouched_restores_the_original_object_rather_than_reparsing() {
        let original = bolded("hi there")
        let (session, view) = session(original)
        session.toggleMode()
        view.string = session.seed.string          // the user typed nothing
        session.toggleMode()
        XCTAssertEqual(session.mode, .formatted)
        XCTAssertTrue(session.seed.isEqual(to: original))
    }

    func test_edited_markup_is_parsed_on_the_way_back() {
        let (session, view) = session(NSAttributedString(string: "hi",
                                                         attributes: ItemEdit.plainDefaults))
        session.toggleMode()
        view.string = "<p><b>changed</b></p>"
        session.toggleMode()
        XCTAssertEqual(session.seed.string, "changed")
        XCTAssertTrue(ItemEdit.carriesFormatting(session.seed))
    }

    func test_an_item_too_large_for_html_refuses_raw_mode_and_says_so() {
        let huge = NSAttributedString(string: String(repeating: "x", count: RichTextHTML.byteCap + 1),
                                      attributes: ItemEdit.plainDefaults)
        let (session, _) = session(huge)
        session.toggleMode()
        XCTAssertEqual(session.mode, .formatted)
        XCTAssertNotNil(session.error)
    }

    // MARK: - What Save gets

    func test_the_draft_in_formatted_mode_is_whatever_is_in_the_view() {
        let (session, view) = session(NSAttributedString(string: "hi",
                                                         attributes: ItemEdit.plainDefaults))
        view.string = "changed"
        XCTAssertEqual(session.resolvedDraft()?.string, "changed")
    }

    func test_the_draft_in_raw_mode_is_the_parsed_markup() {
        let (session, view) = session(NSAttributedString(string: "hi",
                                                         attributes: ItemEdit.plainDefaults))
        session.toggleMode()
        view.string = "<p><b>changed</b></p>"
        let draft = session.resolvedDraft()
        XCTAssertEqual(draft?.string, "changed")
        XCTAssertTrue(ItemEdit.carriesFormatting(draft ?? NSAttributedString()))
    }

    /// Saving straight out of an untouched raw view must not flatten anything either.
    func test_the_draft_in_untouched_raw_mode_is_the_original_object() {
        let original = bolded("hi there")
        let (session, view) = session(original)
        session.toggleMode()
        view.string = session.seed.string
        XCTAssertTrue(session.resolvedDraft()?.isEqual(to: original) ?? false)
    }

    // MARK: - Commands

    func test_running_a_command_changes_the_view_and_refreshes_the_state() {
        let (session, view) = session(NSAttributedString(string: "hello",
                                                         attributes: ItemEdit.plainDefaults))
        view.setSelectedRange(NSRange(location: 0, length: 5))
        session.run(.bold)
        let font = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font ?? ItemEdit.plainFont)
            .contains(.boldFontMask))
        XCTAssertTrue(session.state.bold)
    }
}
