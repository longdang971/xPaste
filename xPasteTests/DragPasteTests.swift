import XCTest
@testable import xPaste

/// The rules a drag out of the panel follows, kept apart from the AppKit session that applies them.
final class DragPasteTests: XCTestCase {

    private func text(_ s: String) -> ClipboardItem { ClipboardItem(type: .text, text: s) }

    // MARK: - Which items travel

    func testDraggingACardOutsideTheSelectionCarriesOnlyThatCard() {
        let a = text("a"), b = text("b"), c = text("c")
        let plan = DragPaste.plan(dragging: c, selection: [a.id, b.id],
                                  displayed: [a, b, c])
        XCTAssertEqual(plan.items.map(\.id), [c.id])
    }

    /// Dragging one of several selected cards takes the whole selection, in the order the panel
    /// shows them — not in the order they happened to be clicked.
    func testDraggingASelectedCardCarriesTheWholeSelectionInPanelOrder() {
        let a = text("a"), b = text("b"), c = text("c")
        let plan = DragPaste.plan(dragging: c, selection: [c.id, a.id],
                                  displayed: [a, b, c])
        XCTAssertEqual(plan.items.map(\.id), [a.id, c.id])
    }

    func testASelectionOfOneCarriesOneItem() {
        let a = text("a")
        let plan = DragPaste.plan(dragging: a, selection: [a.id],
                                  displayed: [a])
        XCTAssertEqual(plan.items.map(\.id), [a.id])
    }

    /// The card can be deleted between the press and the drag passing the threshold.
    func testACardNoLongerOnTheRowCarriesNothing() {
        let gone = text("gone"), a = text("a")
        let plan = DragPaste.plan(dragging: gone, selection: [],
                                  displayed: [a])
        XCTAssertTrue(plan.items.isEmpty)
    }

    // MARK: - The threshold

    func testTheThresholdIgnoresSmallMovementsAndCatchesRealDrags() {
        XCTAssertFalse(DragPaste.exceedsThreshold(from: .zero, to: NSPoint(x: 3, y: 3)))
        XCTAssertTrue(DragPaste.exceedsThreshold(from: .zero, to: NSPoint(x: 0, y: 7)))
        XCTAssertTrue(DragPaste.exceedsThreshold(from: NSPoint(x: 100, y: 100),
                                                 to: NSPoint(x: 92, y: 100)))
    }
}
