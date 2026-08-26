import XCTest
import AppKit
@testable import xPaste

/// Space is what opens the preview, so space is what has to close it — see `PreviewSpaceKey`.
final class PreviewSpaceKeyTests: XCTestCase {

    private func editableField() -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.isEditable = true
        return view
    }

    private func readOnlyPreviewText() -> NSTextView {
        let view = IBeamTextView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.isEditable = false
        view.isSelectable = true
        return view
    }

    func test_space_closes_the_preview() {
        XCTAssertTrue(PreviewSpaceKey.closes(keyCode: 49, modifiers: [], firstResponder: nil))
    }

    /// The case this was written for: a text preview hands first responder to its text view, which
    /// eats the space itself, so the popover stayed open under the key that should have shut it.
    func test_space_closes_the_preview_over_its_own_text_view() {
        XCTAssertTrue(PreviewSpaceKey.closes(keyCode: 49, modifiers: [],
                                             firstResponder: readOnlyPreviewText()))
    }

    /// Anything being typed into keeps its spaces: the search box, a card being renamed, the
    /// editor's text view.
    func test_space_is_left_alone_while_text_is_being_edited() {
        XCTAssertFalse(PreviewSpaceKey.closes(keyCode: 49, modifiers: [],
                                              firstResponder: editableField()))
    }

    func test_other_keys_do_not_close_the_preview() {
        XCTAssertFalse(PreviewSpaceKey.closes(keyCode: 36, modifiers: [], firstResponder: nil))
    }

    /// A modified space belongs to whoever bound it, not to the preview. Caps Lock is not a
    /// modifier anyone binds, so it does not count as one.
    func test_modified_space_does_not_close_the_preview() {
        XCTAssertFalse(PreviewSpaceKey.closes(keyCode: 49, modifiers: .command, firstResponder: nil))
        XCTAssertFalse(PreviewSpaceKey.closes(keyCode: 49, modifiers: .option, firstResponder: nil))
        XCTAssertTrue(PreviewSpaceKey.closes(keyCode: 49, modifiers: .capsLock, firstResponder: nil))
    }

    func test_monitor_stops_cleanly_and_twice_over() {
        let monitor = PreviewSpaceMonitor()
        monitor.start { }
        monitor.stop()
        monitor.stop()
    }
}
