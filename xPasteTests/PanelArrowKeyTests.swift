import XCTest
import AppKit
@testable import xPaste

/// ←/→/↑/↓ walk the row of cards. See `PanelArrowKey` for why that decision is made in the key
/// monitor and not by a hidden `.keyboardShortcut` Button.
final class PanelArrowKeyTests: XCTestCase {

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

    private func step(_ keyCode: UInt16,
                      modifiers: NSEvent.ModifierFlags = [],
                      firstResponder: NSResponder? = nil,
                      inPanel: Bool = true,
                      suggestionsOpen: Bool = false) -> Int? {
        PanelArrowKey.step(keyCode: keyCode, modifiers: modifiers,
                           firstResponder: firstResponder, inPanel: inPanel,
                           suggestionsOpen: suggestionsOpen)
    }

    // MARK: - Which keys, and which way

    func test_left_and_up_walk_backwards() {
        XCTAssertEqual(step(PanelArrowKey.leftKeyCode), -1)
        XCTAssertEqual(step(PanelArrowKey.upKeyCode), -1)
    }

    func test_right_and_down_walk_forwards() {
        XCTAssertEqual(step(PanelArrowKey.rightKeyCode), 1)
        XCTAssertEqual(step(PanelArrowKey.downKeyCode), 1)
    }

    func test_other_keys_are_not_ours() {
        XCTAssertNil(step(49))  // space
        XCTAssertNil(step(36))  // return
        XCTAssertNil(step(51))  // delete
    }

    /// Every arrow on a Mac keyboard arrives carrying `.numericPad` and `.function`. Counting
    /// those as modifiers is how arrow handling gets written once and never fires.
    func test_the_flags_every_arrow_carries_are_not_modifiers() {
        XCTAssertEqual(step(PanelArrowKey.rightKeyCode, modifiers: [.numericPad, .function]), 1)
        XCTAssertEqual(step(PanelArrowKey.rightKeyCode,
                            modifiers: [.numericPad, .function, .capsLock]), 1)
    }

    /// ⌥→ and ⌘→ belong to whoever bound them, not to the panel.
    func test_a_modified_arrow_is_not_ours() {
        XCTAssertNil(step(PanelArrowKey.rightKeyCode, modifiers: [.command, .numericPad, .function]))
        XCTAssertNil(step(PanelArrowKey.rightKeyCode, modifiers: [.option, .numericPad, .function]))
        XCTAssertNil(step(PanelArrowKey.rightKeyCode, modifiers: [.shift, .numericPad, .function]))
    }

    // MARK: - Who owns the arrows while text has focus

    /// A query being typed, a card being renamed, the item editor: the caret is what the arrows
    /// move there.
    func test_text_with_something_in_it_keeps_its_arrows() {
        XCTAssertNil(step(PanelArrowKey.rightKeyCode, firstResponder: editableField("hello")))
        XCTAssertNil(step(PanelArrowKey.leftKeyCode, firstResponder: editableField("hello")))
    }

    /// The bug this rule exists for, and the same one `PreviewSpaceKey` was written for: opening
    /// the filter sheet and closing it again leaves the panel's search box holding first
    /// responder with nothing typed into it. Every arrow after that moved a caret through an
    /// empty string while the user was looking at cards, so the row stopped answering ←/→ at all.
    func test_an_empty_search_box_does_not_own_the_arrows() {
        XCTAssertEqual(step(PanelArrowKey.rightKeyCode, firstResponder: editableField()), 1)
        XCTAssertEqual(step(PanelArrowKey.leftKeyCode, firstResponder: editableField()), -1)
    }

    /// Only the panel's own field is treated that way. An empty field in any other window — a
    /// save panel's name, the editor opened over the panel — is somewhere a caret really lives.
    func test_an_empty_field_outside_the_panel_keeps_its_arrows() {
        XCTAssertNil(step(PanelArrowKey.rightKeyCode, firstResponder: editableField(),
                          inPanel: false))
    }

    /// ↑/↓ drive the filter suggestion list while it is up, and the search field's own monitor is
    /// what reads them. Claiming them here would race that monitor for the same press.
    func test_the_suggestion_list_keeps_the_arrows_while_it_is_up() {
        XCTAssertNil(step(PanelArrowKey.upKeyCode, firstResponder: editableField(),
                          suggestionsOpen: true))
        XCTAssertNil(step(PanelArrowKey.downKeyCode, firstResponder: editableField(),
                          suggestionsOpen: true))
        XCTAssertNil(step(PanelArrowKey.leftKeyCode, firstResponder: editableField(),
                          suggestionsOpen: true))
    }

    /// A preview's text view is read-only: it has no caret to move, so the row still walks with
    /// the popover up — which is what makes ←/→ page through previews.
    func test_a_read_only_preview_does_not_take_the_arrows() {
        XCTAssertEqual(step(PanelArrowKey.rightKeyCode, firstResponder: readOnlyPreviewText(),
                            inPanel: false), 1)
    }
}

/// Where an arrow press leaves the selection.
///
/// Extracted from `ContentView` so the clamping and the empty-selection start can be stated once
/// and held by a test, rather than being re-read off a view body.
final class PanelArrowStepTests: XCTestCase {

    private var items: [UUID] = []

    override func setUp() {
        super.setUp()
        items = (0..<5).map { _ in UUID() }
    }

    private func moved(from selected: Set<UUID>, by delta: Int) -> UUID? {
        PanelSelection.moved(in: items, selected: selected, by: delta)
    }

    func test_right_takes_the_next_card() {
        XCTAssertEqual(moved(from: [items[1]], by: 1), items[2])
    }

    func test_left_takes_the_previous_card() {
        XCTAssertEqual(moved(from: [items[3]], by: -1), items[2])
    }

    /// The row has ends. Walking off one leaves the selection where it is rather than wrapping —
    /// wrapping from the newest card to the oldest is never what the press meant.
    func test_walking_off_the_front_stays_on_the_first_card() {
        XCTAssertEqual(moved(from: [items[0]], by: -1), items[0])
    }

    func test_walking_off_the_back_stays_on_the_last_card() {
        XCTAssertEqual(moved(from: [items[4]], by: 1), items[4])
    }

    /// With nothing selected the first press has to land somewhere: on the end it is walking away
    /// from, so the second press moves one card into the row rather than two.
    func test_the_first_press_with_nothing_selected_lands_on_an_end() {
        XCTAssertEqual(moved(from: [], by: 1), items[0])
        XCTAssertEqual(moved(from: [], by: -1), items[4])
    }

    /// A ⌘-clicked multi-selection collapses onto one card and walks from the topmost of them,
    /// which is the one the highlight reads from.
    func test_a_multi_selection_walks_from_its_topmost_card() {
        XCTAssertEqual(moved(from: [items[3], items[1]], by: 1), items[2])
    }

    /// The row was filtered out from under the selection. Treated as no selection at all rather
    /// than as a reason to do nothing.
    func test_a_selection_that_is_no_longer_on_screen_starts_from_an_end() {
        XCTAssertEqual(moved(from: [UUID()], by: 1), items[0])
    }

    func test_an_empty_row_has_nowhere_to_go() {
        XCTAssertNil(PanelSelection.moved(in: [], selected: [], by: 1))
    }
}

/// Two presses that land on the same card are still two presses.
///
/// The list scrolls off a `.onChange` of the request, and `.onChange` only fires when the value
/// changes. With the card id alone as the request, the second press onto a card the list had
/// already been asked to scroll to was dropped: the highlight moved onto a card that stayed off
/// screen, and the arrow read as having done nothing at all.
final class PanelScrollRequestTests: XCTestCase {

    func test_two_requests_for_the_same_card_differ() {
        let card = UUID()
        let first = PanelScrollRequest(id: card, after: nil)
        let second = PanelScrollRequest(id: card, after: first)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.id, card, "it is still a request to scroll to that card")
    }

    func test_a_run_of_requests_for_one_card_never_repeats_itself() {
        let card = UUID()
        var seen: [PanelScrollRequest] = []
        var last: PanelScrollRequest?
        for _ in 0..<20 {
            let next = PanelScrollRequest(id: card, after: last)
            XCTAssertFalse(seen.contains(next), "a request was repeated, so its scroll is dropped")
            seen.append(next)
            last = next
        }
    }

    func test_a_request_for_another_card_differs_too() {
        let first = PanelScrollRequest(id: UUID(), after: nil)
        XCTAssertNotEqual(first, PanelScrollRequest(id: UUID(), after: first))
    }
}
