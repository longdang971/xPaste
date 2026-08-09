import XCTest
@testable import xPaste

/// The rules a drag out of the panel follows, kept apart from the AppKit session that applies them.
final class DragPasteTests: XCTestCase {

    private func text(_ s: String) -> ClipboardItem { ClipboardItem(type: .text, text: s) }
    private func link(_ s: String) -> ClipboardItem { ClipboardItem(type: .url, text: s) }
    private func image() -> ClipboardItem { ClipboardItem(type: .image, imageData: Data([1, 2, 3])) }
    private func file() -> ClipboardItem {
        ClipboardItem(type: .file, fileURLs: [URL(fileURLWithPath: "/tmp/a.txt")])
    }

    // MARK: - Which items travel

    func testDraggingACardOutsideTheSelectionCarriesOnlyThatCard() {
        let a = text("a"), b = text("b"), c = text("c")
        let plan = DragPaste.plan(dragging: c, selection: [a.id, b.id],
                                  displayed: [a, b, c], accessibilityTrusted: true)
        XCTAssertEqual(plan.items.map(\.id), [c.id])
    }

    /// Dragging one of several selected cards takes the whole selection, in the order the panel
    /// shows them — not in the order they happened to be clicked.
    func testDraggingASelectedCardCarriesTheWholeSelectionInPanelOrder() {
        let a = text("a"), b = text("b"), c = text("c")
        let plan = DragPaste.plan(dragging: c, selection: [c.id, a.id],
                                  displayed: [a, b, c], accessibilityTrusted: true)
        XCTAssertEqual(plan.items.map(\.id), [a.id, c.id])
    }

    func testASelectionOfOneCarriesOneItem() {
        let a = text("a")
        let plan = DragPaste.plan(dragging: a, selection: [a.id],
                                  displayed: [a], accessibilityTrusted: true)
        XCTAssertEqual(plan.items.map(\.id), [a.id])
    }

    /// The card can be deleted between the press and the drag passing the threshold.
    func testACardNoLongerOnTheRowCarriesNothing() {
        let gone = text("gone"), a = text("a")
        let plan = DragPaste.plan(dragging: gone, selection: [],
                                  displayed: [a], accessibilityTrusted: true)
        XCTAssertTrue(plan.items.isEmpty)
    }

    // MARK: - Which payload it travels under

    func testTextAndLinksTravelAsADeferredPaste() {
        let a = text("a"), b = link("https://example.com")
        let plan = DragPaste.plan(dragging: a, selection: [a.id, b.id],
                                  displayed: [a, b], accessibilityTrusted: true)
        XCTAssertEqual(plan.kind, .deferredPaste)
    }

    /// Drag and drop is the only way into a web upload zone or a Finder window, so anything that is
    /// not text keeps the real payload.
    func testAnythingButTextTravelsNatively() {
        let candidates = [image(), file(),
                          ClipboardItem(type: .folder, fileURLs: [URL(fileURLWithPath: "/tmp")])]
        for item in candidates {
            let plan = DragPaste.plan(dragging: item, selection: [],
                                      displayed: [item], accessibilityTrusted: true)
            XCTAssertEqual(plan.kind, .native, "\(item.type) must keep its real payload")
        }
    }

    func testAMixedSelectionTravelsNatively() {
        let a = text("a"), b = image()
        let plan = DragPaste.plan(dragging: a, selection: [a.id, b.id],
                                  displayed: [a, b], accessibilityTrusted: true)
        XCTAssertEqual(plan.kind, .native)
    }

    /// Without Accessibility there is no way to press ⌘V, so a deferred paste could never be
    /// delivered. Falling back to the real payload keeps dragging working exactly as it did before.
    func testTextTravelsNativelyWithoutAccessibility() {
        let a = text("a")
        let plan = DragPaste.plan(dragging: a, selection: [],
                                  displayed: [a], accessibilityTrusted: false)
        XCTAssertEqual(plan.kind, .native)
    }

    // MARK: - The threshold

    func testTheThresholdIgnoresSmallMovementsAndCatchesRealDrags() {
        XCTAssertFalse(DragPaste.exceedsThreshold(from: .zero, to: NSPoint(x: 3, y: 3)))
        XCTAssertTrue(DragPaste.exceedsThreshold(from: .zero, to: NSPoint(x: 0, y: 7)))
        XCTAssertTrue(DragPaste.exceedsThreshold(from: NSPoint(x: 100, y: 100),
                                                 to: NSPoint(x: 92, y: 100)))
    }

    // MARK: - What gets written

    /// A single item keeps its formatting, the same way ⏎ and a double-click already paste it.
    func testASingleItemPastesAsItself() {
        let a = text("hello")
        let plan = DragPaste.Plan(items: [a], kind: .deferredPaste)
        XCTAssertEqual(DragPaste.content(for: plan, shiftHeld: false, alwaysPlainText: false,
                                         separator: .newline),
                       .item(a))
    }

    func testShiftOnReleasePastesPlainText() {
        let a = ClipboardItem(type: .text, text: "hello", richData: Data([9]), richType: "public.rtf")
        XCTAssertEqual(DragPaste.content(for: DragPaste.Plan(items: [a], kind: .deferredPaste),
                                         shiftHeld: true, alwaysPlainText: false,
                                         separator: .newline),
                       .plain("hello"))
    }

    func testTheAlwaysPlainTextSettingIsHonoured() {
        let a = ClipboardItem(type: .text, text: "hello", richData: Data([9]), richType: "public.rtf")
        XCTAssertEqual(DragPaste.content(for: DragPaste.Plan(items: [a], kind: .deferredPaste),
                                         shiftHeld: false, alwaysPlainText: true,
                                         separator: .newline),
                       .plain("hello"))
    }

    func testAGroupIsJoinedWithTheChosenSeparator() {
        let a = text("one"), b = text("two")
        XCTAssertEqual(DragPaste.content(for: DragPaste.Plan(items: [a, b], kind: .deferredPaste),
                                         shiftHeld: false, alwaysPlainText: false,
                                         separator: .comma),
                       .plain("one, two"))
    }

    /// Two unnamed images have no text between them, so there is nothing to join: fall back to
    /// pasting the first item itself, which can still carry the picture.
    func testAGroupWithNothingToJoinFallsBackToTheFirstItem() {
        let a = image(), b = image()
        XCTAssertEqual(DragPaste.content(for: DragPaste.Plan(items: [a, b], kind: .native),
                                         shiftHeld: false, alwaysPlainText: false,
                                         separator: .newline),
                       .item(a))
    }

    func testAnEmptyPlanWritesNothing() {
        XCTAssertNil(DragPaste.content(for: DragPaste.Plan(items: [], kind: .deferredPaste),
                                       shiftHeld: false, alwaysPlainText: false,
                                       separator: .newline))
    }

    // MARK: - How much to select afterwards

    func testSelectableLengthCountsUTF16Units() {
        XCTAssertEqual(DragPaste.selectableLength(of: .plain("hello")), 5)
        XCTAssertEqual(DragPaste.selectableLength(of: .item(text("xin chào"))), 8)
    }

    /// An emoji is two UTF-16 units, and the Accessibility ranges we hand back are measured in
    /// exactly those units — counting characters would select too little.
    func testSelectableLengthCountsAnEmojiAsTwo() {
        XCTAssertEqual(DragPaste.selectableLength(of: .plain("a🙂")), 3)
    }

    /// Pasting a picture or a file inserts something that is not text, so there is no range to
    /// select and the selection pass must be skipped rather than guessed at.
    func testThereIsNothingToSelectForAPictureOrAFile() {
        XCTAssertNil(DragPaste.selectableLength(of: .item(image())))
        XCTAssertNil(DragPaste.selectableLength(of: .item(file())))
    }
}
