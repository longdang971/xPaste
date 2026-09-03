import XCTest
import AppKit
@testable import xPaste

/// Space is what opens the preview and what puts it away — one press, one flip, decided in one
/// place. See `PreviewSpaceKey`.
final class PreviewSpaceKeyTests: XCTestCase {

    private func editableField(_ text: String = "") -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.isEditable = true
        view.string = text
        return view
    }

    private func readOnlyPreviewText() -> NSTextView {
        let view = IBeamTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.isEditable = false
        view.isSelectable = true
        return view
    }

    func test_space_toggles_the_preview() {
        XCTAssertTrue(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: [], firstResponder: nil,
                                                     inPanel: true))
    }

    /// The case this was written for: a text preview hands first responder to its text view, which
    /// eats the space itself, so the popover stayed open under the key that should have shut it.
    func test_space_toggles_the_preview_over_its_own_text_view() {
        XCTAssertTrue(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: [],
                                                     firstResponder: readOnlyPreviewText(),
                                                     inPanel: false))
    }

    /// Anything with something typed into it keeps its spaces: a query being written, a card
    /// being renamed, the editor's text view.
    func test_space_is_left_alone_while_text_is_being_edited() {
        XCTAssertFalse(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: [],
                                                      firstResponder: editableField("hello"),
                                                      inPanel: true))
    }

    /// The bug this rule exists for: opening the filter sheet and closing it again leaves the
    /// search box holding first responder, so every space after that was typed into an empty
    /// query and the preview stopped answering Space at all.
    func test_space_toggles_the_preview_over_an_empty_search_box() {
        XCTAssertTrue(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: [],
                                                     firstResponder: editableField(),
                                                     inPanel: true))
    }

    /// Only the panel's own field is treated that way. An empty text field in any other window —
    /// a save panel's name, an editor opened over the panel — is somewhere a space is being typed.
    func test_space_is_left_alone_in_an_empty_field_outside_the_panel() {
        XCTAssertFalse(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: [],
                                                      firstResponder: editableField(),
                                                      inPanel: false))
    }

    func test_other_keys_do_not_toggle_the_preview() {
        XCTAssertFalse(PreviewSpaceKey.togglesPreview(keyCode: 36, modifiers: [], firstResponder: nil,
                                                      inPanel: true))
    }

    /// A modified space belongs to whoever bound it, not to the preview. Caps Lock is not a
    /// modifier anyone binds, so it does not count as one.
    func test_modified_space_does_not_toggle_the_preview() {
        XCTAssertFalse(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: .command,
                                                      firstResponder: nil, inPanel: true))
        XCTAssertFalse(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: .option,
                                                      firstResponder: nil, inPanel: true))
        XCTAssertTrue(PreviewSpaceKey.togglesPreview(keyCode: 49, modifiers: .capsLock,
                                                     firstResponder: nil, inPanel: true))
    }
}

/// What each space press does to the preview.
///
/// Spamming space used to drop presses: the popover's own key monitor swallowed every space for as
/// long as its content view was alive — which outlasts the closing animation — and the press that
/// should have reopened the preview never reached the panel. One object decides now, so press N
/// always lands in the opposite state from press N-1.
final class PanelPreviewTests: XCTestCase {

    private var preview: PanelPreview { .shared }

    override func setUp() {
        super.setUp()
        preview.close()
    }

    override func tearDown() {
        preview.close()
        super.tearDown()
    }

    func test_space_on_a_card_opens_its_preview() {
        let card = UUID()
        preview.toggle(card)
        XCTAssertEqual(preview.itemID, card)
    }

    func test_space_again_on_the_same_card_closes_it() {
        let card = UUID()
        preview.toggle(card)
        preview.toggle(card)
        XCTAssertNil(preview.itemID)
    }

    /// The spam case, in the only terms a test can hold it: every press flips, none is dropped.
    func test_every_press_flips_the_preview() {
        let card = UUID()
        for press in 1...9 {
            preview.toggle(card)
            XCTAssertEqual(preview.itemID, press.isMultiple(of: 2) ? nil : card,
                           "press \(press) did not land")
        }
    }

    /// Space with another card selected moves the preview rather than closing it — the arrow keys
    /// walk the row with the preview up.
    func test_space_on_a_different_card_moves_the_preview() {
        let first = UUID(), second = UUID()
        preview.toggle(first)
        preview.toggle(second)
        XCTAssertEqual(preview.itemID, second)
    }

    func test_presenting_the_card_already_shown_changes_nothing() {
        let card = UUID()
        preview.present(card)
        preview.present(card)
        XCTAssertEqual(preview.itemID, card)
    }
}
