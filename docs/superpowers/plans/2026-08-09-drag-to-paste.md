# Drag-to-paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dragging a card out of the panel carries it to an application and pastes it there, so a
selection is replaced and the pasted text is left selected.

**Architecture:** The panel already intercepts every mouse event in `ClipboardPanel.sendEvent`; it
gains drag detection and posts a notification, and the card under the press starts an AppKit dragging
session. Text and link items travel under a private pasteboard type no application accepts, so
nothing is inserted by a drop and the release instead triggers a real `⌘V` into the app under the
pointer, followed by an Accessibility call that selects what was inserted. Images, files and folders
keep the real payload they have today.

**Tech Stack:** Swift 5.9, AppKit (`NSDraggingSource`, `NSPasteboardItem`), SwiftUI
(`NSViewRepresentable`), ApplicationServices (`AXUIElement`), CoreGraphics (`CGWindowListCopyWindowInfo`),
XCTest.

Spec: `docs/superpowers/specs/2026-08-09-drag-to-paste-design.md`

## Global Constraints

- Deployment target macOS 13.0; `SWIFT_VERSION` 5.9. Nothing may require a later SDK without an
  `@available` guard.
- Build and test with `xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug`.
  Always `cd /Users/pikalong/xPaste` in the *same* command as `xcodebuild`: the shell's working
  directory resets between calls and the build silently targets the wrong directory.
- After adding or removing a source file, run `xcodegen generate` before building — the project is
  generated from `project.yml`.
- SourceKit reports bogus "Cannot find X in scope" diagnostics across this project. Trust
  `xcodebuild`, not the editor diagnostics.
- The pasteboard must only ever be written **after** a drag has ended. A cancelled drag must leave
  `NSPasteboard.general` untouched.
- Every pasteboard write on the paste path must be preceded by
  `ClipboardMonitor.shared.markNextChangeAsOwn()` so the monitor does not re-capture it as a new item.
- The private drag type is the string `com.user.xPaste.deferred-paste`, declared once in
  `DragPaste.deferredType`.
- The drag threshold is 6 points.
- The delay between posting `⌘V` and the Accessibility selection call is 90ms.
- Perf floor: the panel open path must stay at or below what it measures now — 19-32ms to open, zero
  dropped frames on the reveal, measured with
  `XPASTE_PERF=1 XPASTE_AUTOOPEN=8 XPASTE_COPIES=2 <Release binary>`.

---

### Task 0: Spike — DONE

Both questions were answered with a throwaway drag source and a synthetic drag; the findings are
written up in the spec's "What the spike settled" section.

- **A session survives its source window being ordered out.** `movedTo` kept firing after the
  `orderOut`, right to the release point. `hidePanel()` on drag begin stands; the `alphaValue = 0`
  fallback is not needed.
- **A synthetic release cannot end a session.** Neither event tap, with or without
  `mouseEventClickState`, produced `draggingSession(_:endedAt:operation:)`; only a physical release
  does. This changed two things below: the cancel test is *positive* (Task 5), and the end-to-end
  verification drives the tail of the pipeline through a debug hook rather than a synthetic drop
  (Tasks 5 and 6).

---

### Task 1: `DragPaste` — the rules, with tests

**Files:**
- Create: `xPaste/Services/DragPaste.swift`
- Create: `xPasteTests/DragPasteTests.swift`

**Interfaces:**
- Consumes: `ClipboardItem`, `ClipboardContentType`, `MultiPaste.Separator`, `MultiPaste.joinedText(for:separator:)`.
- Produces:
  - `DragPaste.deferredType: NSPasteboard.PasteboardType`
  - `struct DragPaste.Plan { let items: [ClipboardItem]; let kind: DragPaste.PayloadKind }`
  - `enum DragPaste.PayloadKind { case deferredPaste, native }`
  - `enum DragPaste.PasteContent: Equatable { case item(ClipboardItem); case plain(String) }`
  - `DragPaste.plan(dragging:selection:displayed:accessibilityTrusted:) -> Plan`
  - `DragPaste.exceedsThreshold(from:to:) -> Bool`
  - `DragPaste.content(for:shiftHeld:alwaysPlainText:separator:) -> PasteContent?`
  - `DragPaste.selectableLength(of:) -> Int?`

- [ ] **Step 1: Write the failing tests**

```swift
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
        for item in [image(), file(), ClipboardItem(type: .folder, fileURLs: [URL(fileURLWithPath: "/tmp")])] {
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
        XCTAssertTrue(DragPaste.exceedsThreshold(from: NSPoint(x: 100, y: 100), to: NSPoint(x: 92, y: 100)))
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
                                         shiftHeld: true, alwaysPlainText: false, separator: .newline),
                       .plain("hello"))
    }

    func testTheAlwaysPlainTextSettingIsHonoured() {
        let a = ClipboardItem(type: .text, text: "hello", richData: Data([9]), richType: "public.rtf")
        XCTAssertEqual(DragPaste.content(for: DragPaste.Plan(items: [a], kind: .deferredPaste),
                                         shiftHeld: false, alwaysPlainText: true, separator: .newline),
                       .plain("hello"))
    }

    func testAGroupIsJoinedWithTheChosenSeparator() {
        let a = text("one"), b = text("two")
        XCTAssertEqual(DragPaste.content(for: DragPaste.Plan(items: [a, b], kind: .deferredPaste),
                                         shiftHeld: false, alwaysPlainText: false, separator: .comma),
                       .plain("one, two"))
    }

    /// Two selected images have no text between them, so there is nothing to join: fall back to
    /// pasting the first item itself, which can still carry the picture.
    func testAGroupWithNothingToJoinFallsBackToTheFirstItem() {
        let a = image(), b = image()
        XCTAssertEqual(DragPaste.content(for: DragPaste.Plan(items: [a, b], kind: .native),
                                         shiftHeld: false, alwaysPlainText: false, separator: .newline),
                       .item(a))
    }

    func testAnEmptyPlanWritesNothing() {
        XCTAssertNil(DragPaste.content(for: DragPaste.Plan(items: [], kind: .deferredPaste),
                                       shiftHeld: false, alwaysPlainText: false, separator: .newline))
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
```

- [ ] **Step 2: Run them and watch them fail**

```bash
cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|DragPasteTests|\*\* TEST"
```

Expected: compilation fails with "Cannot find 'DragPaste' in scope".

- [ ] **Step 3: Write `DragPaste`**

```swift
import AppKit

/// The rules a drag out of the panel follows.
///
/// All of it is decisions — which cards travel, under what payload, what ends up on the pasteboard —
/// with no AppKit session anywhere near it, so every rule here is tested directly.
enum DragPaste {

    /// The only type a deferred paste puts on the dragging pasteboard.
    ///
    /// Deliberately private to xPaste and declared nowhere else: no application registers it, so no
    /// application accepts the drop, so nothing is inserted anywhere and the release is free to mean
    /// "paste this here" instead.
    static let deferredType = NSPasteboard.PasteboardType("com.user.xPaste.deferred-paste")

    /// How far the pointer has to travel before a press becomes a drag rather than a click.
    static let threshold: CGFloat = 6

    enum PayloadKind {
        /// Nothing droppable: the release triggers a real paste.
        case deferredPaste
        /// The item's own representation, so a drop into Finder or a web upload zone still works.
        case native
    }

    struct Plan {
        let items: [ClipboardItem]
        let kind: PayloadKind
    }

    /// What to put on the pasteboard when the drag has ended.
    enum PasteContent: Equatable {
        /// The item itself, keeping any formatting it captured.
        case item(ClipboardItem)
        /// This exact string, unformatted.
        case plain(String)

        static func == (a: PasteContent, b: PasteContent) -> Bool {
            switch (a, b) {
            case let (.item(x), .item(y)):   return x.id == y.id
            case let (.plain(x), .plain(y)): return x == y
            default:                          return false
            }
        }
    }

    static func exceedsThreshold(from: NSPoint, to: NSPoint) -> Bool {
        abs(to.x - from.x) > threshold || abs(to.y - from.y) > threshold
    }

    /// Which cards a drag started on `dragged` carries, and under which payload.
    ///
    /// Dragging a card that is part of a multi-selection takes the whole selection, in the order the
    /// panel shows it — the order cards were clicked in is not an order anybody meant.
    static func plan(dragging dragged: ClipboardItem,
                     selection: Set<UUID>,
                     displayed: [ClipboardItem],
                     accessibilityTrusted: Bool) -> Plan {
        let items: [ClipboardItem]
        if selection.contains(dragged.id), selection.count > 1 {
            items = displayed.filter { selection.contains($0.id) }
        } else {
            items = displayed.contains(where: { $0.id == dragged.id }) ? [dragged] : []
        }
        return Plan(items: items, kind: kind(for: items, accessibilityTrusted: accessibilityTrusted))
    }

    private static func kind(for items: [ClipboardItem], accessibilityTrusted: Bool) -> PayloadKind {
        guard accessibilityTrusted else { return .native }
        let allText = !items.isEmpty && items.allSatisfy { $0.type == .text || $0.type == .url }
        return allText ? .deferredPaste : .native
    }

    /// What the release should write to the pasteboard, or nil when there is nothing to write.
    static func content(for plan: Plan, shiftHeld: Bool, alwaysPlainText: Bool,
                        separator: MultiPaste.Separator) -> PasteContent? {
        guard let first = plan.items.first else { return nil }
        if plan.items.count > 1 {
            // A group is always plain: there is no such thing as one piece of formatting spanning
            // several unrelated captures.
            if let joined = MultiPaste.joinedText(for: plan.items, separator: separator) {
                return .plain(joined)
            }
            return .item(first)
        }
        if shiftHeld || alwaysPlainText, let text = first.text {
            return .plain(text)
        }
        return .item(first)
    }

    /// How many UTF-16 units the paste will insert, or nil when what lands is not text and so has no
    /// range to select. UTF-16 because that is the unit Accessibility text ranges are measured in.
    static func selectableLength(of content: PasteContent) -> Int? {
        switch content {
        case let .plain(text):
            return text.utf16.count
        case let .item(item):
            guard item.type == .text || item.type == .url, let text = item.text else { return nil }
            return text.utf16.count
        }
    }
}
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|DragPasteTests' (passed|failed)|\*\* TEST"
```

Expected: `Test Suite 'DragPasteTests' passed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/Services/DragPaste.swift xPasteTests/DragPasteTests.swift xPaste.xcodeproj && git commit -m "Decide what a drag out of the panel carries"
```

---

### Task 2: `AXTextSelection` — select what was just pasted

**Files:**
- Create: `xPaste/Services/AXTextSelection.swift`
- Create: `xPasteTests/AXTextSelectionTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `AXTextSelection.rangeCoveringInsertion(caretAt:length:) -> CFRange`
  - `AXTextSelection.selectPastedText(pid: pid_t, length: Int)`

- [ ] **Step 1: Write the failing tests for the range arithmetic**

```swift
import XCTest
@testable import xPaste

/// The arithmetic behind "select what was just pasted".
///
/// It is separated from the Accessibility calls because this is where a wrong answer does damage: a
/// negative or over-long range handed to another application selects the wrong text, or throws.
final class AXTextSelectionTests: XCTestCase {

    func testTheRangeWalksBackFromTheCaretByTheLengthInserted() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 20, length: 5)
        XCTAssertEqual(r.location, 15)
        XCTAssertEqual(r.length, 5)
    }

    /// The caret can sit earlier than the insertion is long — the target may have normalised
    /// newlines away, or refused part of the paste. Clamp rather than hand back a negative location.
    func testACaretShorterThanTheInsertionClampsToTheStart() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 3, length: 10)
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 3)
    }

    func testACaretAtTheStartSelectsNothing() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 0, length: 4)
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, 0)
    }

    func testNothingInsertedSelectsNothing() {
        let r = AXTextSelection.rangeCoveringInsertion(caretAt: 12, length: 0)
        XCTAssertEqual(r.location, 12)
        XCTAssertEqual(r.length, 0)
    }
}
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|AXTextSelectionTests|\*\* TEST"
```

Expected: "Cannot find 'AXTextSelection' in scope".

- [ ] **Step 3: Write `AXTextSelection`**

```swift
import AppKit
import ApplicationServices

/// Leaves the text a paste just inserted selected, so it can be typed straight over.
///
/// A paste puts the caret at the end of what it inserted, which is all we get to work from: walk
/// back from there by as much as we wrote. Everything here fails quietly. Whether an application
/// exposes a writable selection over Accessibility is entirely up to it — native text views do,
/// browsers and Electron apps often do not — and a drag that pasted correctly must not report an
/// error because the highlight could not be applied afterwards.
enum AXTextSelection {

    /// The range covering an insertion of `length` that finished with the caret at `caretAt`.
    ///
    /// Clamped to the start of the text: the caret can legitimately sit earlier than the insertion
    /// was long, and a negative location would be rejected by the target — or worse, accepted.
    static func rangeCoveringInsertion(caretAt caret: Int, length: Int) -> CFRange {
        let selectable = max(0, min(length, caret))
        return CFRange(location: caret - selectable, length: selectable)
    }

    /// Selects the last `length` UTF-16 units before the caret in `pid`'s focused text element.
    static func selectPastedText(pid: pid_t, length: Int) {
        guard length > 0 else { return }
        let app = AXUIElementCreateApplication(pid)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused as! AXUIElement? else { return }

        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &current) == .success,
              let value = current, CFGetTypeID(value) == AXValueGetTypeID() else { return }

        var caretRange = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &caretRange) else { return }

        var target = rangeCoveringInsertion(caretAt: caretRange.location, length: length)
        guard target.length > 0,
              let newValue = AXValueCreate(.cfRange, &target) else { return }
        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newValue)
    }
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|AXTextSelectionTests' (passed|failed)|\*\* TEST"
```

Expected: `Test Suite 'AXTextSelectionTests' passed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/Services/AXTextSelection.swift xPasteTests/AXTextSelectionTests.swift xPaste.xcodeproj && git commit -m "Select the text a paste just inserted"
```

---

### Task 3: `DropTargetResolver` — which application was under the pointer

**Files:**
- Create: `xPaste/Services/DropTargetResolver.swift`
- Create: `xPasteTests/DropTargetResolverTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct DropTargetResolver.Window { let pid: pid_t; let bounds: CGRect; let layer: Int }`
  - `DropTargetResolver.owner(of:in:excluding:) -> pid_t?`
  - `DropTargetResolver.pid(under screenPoint: NSPoint) -> pid_t?`

- [ ] **Step 1: Write the failing tests**

Note the coordinate systems: `CGWindowListCopyWindowInfo` reports bounds with a **top-left** origin,
while an `NSPoint` from a dragging session is **bottom-left**. `owner(of:in:excluding:)` works in the
top-left space, and the conversion happens in `pid(under:)`.

```swift
import XCTest
@testable import xPaste

/// Choosing the application a drop landed on.
final class DropTargetResolverTests: XCTestCase {

    private func window(_ pid: pid_t, _ rect: CGRect, layer: Int = 0) -> DropTargetResolver.Window {
        DropTargetResolver.Window(pid: pid, bounds: rect, layer: layer)
    }

    /// The list arrives front to back, so the first window containing the point is the one on top.
    func testTheFrontmostWindowUnderThePointWins() {
        let front = window(11, CGRect(x: 0, y: 0, width: 500, height: 500))
        let behind = window(22, CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10),
                                                in: [front, behind], excluding: 99), 11)
    }

    func testWindowsThatDoNotContainThePointAreSkipped() {
        let left = window(11, CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = window(22, CGRect(x: 200, y: 0, width: 100, height: 100))
        XCTAssertEqual(DropTargetResolver.owner(of: CGPoint(x: 250, y: 50),
                                                in: [left, right], excluding: 99), 22)
    }

    /// xPaste's own windows are never the target: the panel is what the item was dragged out of.
    func testOurOwnWindowsAreIgnored() {
        let ours = window(42, CGRect(x: 0, y: 0, width: 500, height: 500))
        let theirs = window(11, CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10),
                                                in: [ours, theirs], excluding: 42), 11)
    }

    /// The menu bar, the Dock and every other piece of system furniture sit above the normal window
    /// layer. Releasing over them means "no application", not "paste into the Dock".
    func testWindowsAboveTheNormalLayerAreIgnored() {
        let dock = window(33, CGRect(x: 0, y: 0, width: 500, height: 500), layer: 20)
        XCTAssertNil(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10),
                                              in: [dock], excluding: 99))
    }

    func testNothingUnderThePointIsNoTarget() {
        XCTAssertNil(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10), in: [], excluding: 99))
    }
}
```

- [ ] **Step 2: Run and watch them fail**

```bash
cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|DropTargetResolverTests|\*\* TEST"
```

Expected: "Cannot find 'DropTargetResolver' in scope".

- [ ] **Step 3: Write `DropTargetResolver`**

```swift
import AppKit

/// Which application a drag was released over.
///
/// The release point picks the application, not the insertion point inside it: the paste that
/// follows lands wherever that application's own caret or selection already is. Clicking at the
/// release point to move the caret would destroy the selection the paste is meant to replace, which
/// is the whole reason this feature exists.
enum DropTargetResolver {

    /// One on-screen window, as much of it as the choice depends on.
    struct Window: Equatable {
        let pid: pid_t
        /// Top-left origin, the way `CGWindowListCopyWindowInfo` reports it.
        let bounds: CGRect
        /// `kCGWindowLayer`. Ordinary application windows are 0; the Dock, the menu bar and other
        /// system furniture sit above.
        let layer: Int
    }

    /// The owner of the frontmost ordinary window containing `point`.
    ///
    /// `windows` must be front-to-back, which is the order `CGWindowListCopyWindowInfo` returns.
    static func owner(of point: CGPoint, in windows: [Window], excluding excluded: pid_t) -> pid_t? {
        windows.first { $0.layer == 0 && $0.pid != excluded && $0.bounds.contains(point) }?.pid
    }

    /// The application under a point given in screen coordinates.
    static func pid(under screenPoint: NSPoint) -> pid_t? {
        guard let primary = NSScreen.screens.first else { return nil }
        // Dragging sessions report a bottom-left origin; the window list uses top-left, measured
        // from the top of the primary display.
        let flipped = CGPoint(x: screenPoint.x, y: primary.frame.maxY - screenPoint.y)
        return owner(of: flipped, in: onScreenWindows(), excluding: ProcessInfo.processInfo.processIdentifier)
    }

    private static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return Window(pid: pid, bounds: bounds, layer: layer)
        }
    }
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|DropTargetResolverTests' (passed|failed)|\*\* TEST"
```

Expected: `Test Suite 'DropTargetResolverTests' passed`.

- [ ] **Step 5: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/Services/DropTargetResolver.swift xPasteTests/DropTargetResolverTests.swift xPaste.xcodeproj && git commit -m "Find the application a drag was released over"
```

---

### Task 4: Paste into a chosen application, and select what landed

Extends the existing paste path rather than adding a second one.

**Files:**
- Modify: `xPaste/App/AppDelegate.swift` (`handlePasteItem`, the notification list)

**Interfaces:**
- Consumes: `AXTextSelection.selectPastedText(pid:length:)`.
- Produces: `.pasteClipboardItem` now understands two optional `userInfo` keys — `"targetPID"`
  (`pid_t`) and `"selectLength"` (`Int`). Both absent means exactly today's behaviour.

- [ ] **Step 1: Extend `handlePasteItem`**

Replace the body of `handlePasteItem` with:

```swift
    @objc private func handlePasteItem(_ note: Notification) {
        guard AccessibilityPermission.isTrusted else {
            hidePanel()
            AccessibilityPermission.requestSystemPrompt()
            AccessibilityPermission.openSystemSettings()
            return
        }
        // A drag names the application it was released over; a keyboard paste means the app the
        // panel was opened in front of.
        let requested = (note.userInfo?["targetPID"] as? pid_t)
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        let target = requested ?? previousApp
        let targetPID = target?.processIdentifier ?? 0
        // Only a drag asks for this: it is what leaves the pasted text selected so it can be typed
        // straight over. See AXTextSelection.
        let selectLength = note.userInfo?["selectLength"] as? Int
        // Slide the panel closed (down) and refocus the target app, then post ⌘V after a short
        // settle delay. The reorder-freeze that used to make this janky is fixed, so the close
        // animation stays smooth even during a paste.
        hidePanel()
        target?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            let src = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
            if targetPID > 0 {
                keyDown?.postToPid(targetPID)
                keyUp?.postToPid(targetPID)
            } else {
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
            guard let selectLength, targetPID > 0 else { return }
            // Long enough for the target to have processed the keystroke and moved its caret; the
            // selection is read back from wherever that ended up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                AXTextSelection.selectPastedText(pid: targetPID, length: selectLength)
            }
        }
    }
```

- [ ] **Step 2: Build**

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug build 2>&1 | grep -E "error:|BUILD"
```

Expected: `** BUILD SUCCEEDED **`. `handlePasteItem` is registered with
`#selector(handlePasteItem)`; a selector taking a `Notification` still matches, so the
`addObserver` call needs no change.

- [ ] **Step 3: Run the whole suite, to be sure the existing paste tests still hold**

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|Test Suite 'All tests'|\*\* TEST"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/App/AppDelegate.swift && git commit -m "Let a paste name its target application and what to select"
```

---

### Task 5: The drag session itself

**Files:**
- Create: `xPaste/Views/CardDragSource.swift`
- Modify: `xPaste/App/AppDelegate.swift` (`Notification.Name` list, `ClipboardPanel.sendEvent`,
  drag began/cancelled handling in `applicationDidFinishLaunching`)
- Modify: `xPaste/Views/ContentView.swift` (both list layouts, `dragProvider` removal)

**Interfaces:**
- Consumes: `DragPaste`, `DropTargetResolver.pid(under:)`, `.pasteClipboardItem` with `targetPID`
  and `selectLength`.
- Produces:
  - `.dragOutOfPanel`, `.panelDragBegan`, `.panelDragCancelled` notifications
  - `struct CardDragSource: NSViewRepresentable`, taking `plan: () -> DragPaste.Plan` and
    `onEnded: (DragPaste.Plan, NSPoint, NSDragOperation, Bool, Bool) -> Void` — the plan, the
    release point, the operation the target reported, whether ⇧ was held, and whether it was
    cancelled.

- [ ] **Step 1: Add the three notifications**

In the `extension Notification.Name` block in `AppDelegate.swift`, beside `doubleClickInPanel`:

```swift
    static let dragOutOfPanel       = Notification.Name("com.user.xPaste.dragOutOfPanel")
    static let panelDragBegan       = Notification.Name("com.user.xPaste.panelDragBegan")
    static let panelDragCancelled   = Notification.Name("com.user.xPaste.panelDragCancelled")
```

- [ ] **Step 2: Detect the drag in `ClipboardPanel.sendEvent`**

Add to `ClipboardPanel`:

```swift
    /// Where the current press started, while it could still turn into a drag.
    private var pressOrigin: NSPoint?
```

In `sendEvent`, inside `case .leftMouseDown`, immediately after the ⌘ and double-click branches
return (i.e. just before the existing `let loc = event.locationInWindow` line), record the press:

```swift
            // A plain press might still become a drag out of the panel. ⌘-presses are
            // multi-selection and double-clicks paste, so neither is a drag.
            pressOrigin = event.locationInWindow
```

Then add two cases to the `switch`, before `default`:

```swift
        case .leftMouseDragged:
            if let origin = pressOrigin,
               DragPaste.exceedsThreshold(from: origin, to: event.locationInWindow) {
                pressOrigin = nil
                // The card is found from where the press started, not from where the pointer is
                // now — by this point it has already left the card it began on.
                NotificationCenter.default.post(
                    name: .dragOutOfPanel,
                    object: nil,
                    userInfo: ["locationInWindow": origin, "event": event]
                )
                return
            }

        case .leftMouseUp:
            pressOrigin = nil
```

- [ ] **Step 3: Hide the panel while the drag runs, and bring it back on a cancel**

In `applicationDidFinishLaunching`, beside the other observers:

```swift
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePanelDragBegan),
            name: .panelDragBegan, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePanelDragCancelled),
            name: .panelDragCancelled, object: nil
        )
```

And beside `handleAlertShown`:

```swift
    /// The panel gets out of the way for the length of a drag: it covers the strip of screen the
    /// item may be headed for, and leaving it up afterwards means reaching for Escape every time.
    @objc private func handlePanelDragBegan() { hidePanel() }

    /// Escape during a drag puts everything back, including the panel. Nothing has been written to
    /// the pasteboard at this point — that only happens once a drag has ended in a paste.
    @objc private func handlePanelDragCancelled() {
        guard !panelVisible else { return }
        showPanel()
    }
```

> If Task 0's spike found that a session does **not** survive `orderOut`, replace
> `handlePanelDragBegan` with `panel.map { $0.alphaValue = 0 }` and restore `alphaValue = 1` plus a
> `hidePanel()` from the end-of-drag handler instead.

- [ ] **Step 4: Write `CardDragSource`**

```swift
import SwiftUI
import AppKit

/// Starts the AppKit dragging session for one card, and reports where it ended.
///
/// The session has to be AppKit's rather than SwiftUI's `.onDrag`: SwiftUI owns the session it
/// creates and tells us nothing about it, and this feature turns entirely on knowing where the drag
/// was released, whether ⇧ was held there, and whether the target took the drop at all.
///
/// It does not decide anything — `DragPaste` does. This only carries the decision out.
struct CardDragSource: NSViewRepresentable {
    /// Worked out when the drag actually starts, not when the view is built: the selection may have
    /// moved in between.
    let plan: () -> DragPaste.Plan
    /// The plan, where it was released, what the target reported, whether ⇧ was held, whether it
    /// was cancelled.
    let onEnded: (DragPaste.Plan, NSPoint, NSDragOperation, Bool, Bool) -> Void

    func makeNSView(context: Context) -> CardDragSourceView {
        CardDragSourceView(plan: plan, onEnded: onEnded)
    }

    func updateNSView(_ nsView: CardDragSourceView, context: Context) {
        nsView.plan = plan
        nsView.onEnded = onEnded
    }
}

final class CardDragSourceView: NSView, NSDraggingSource {
    var plan: () -> DragPaste.Plan
    var onEnded: (DragPaste.Plan, NSPoint, NSDragOperation, Bool, Bool) -> Void
    private var observer: NSObjectProtocol?
    private var draggingPlan: DragPaste.Plan?

    init(plan: @escaping () -> DragPaste.Plan,
         onEnded: @escaping (DragPaste.Plan, NSPoint, NSDragOperation, Bool, Bool) -> Void) {
        self.plan = plan
        self.onEnded = onEnded
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Claims nothing: the card underneath keeps its click, double-click and ⌘-click handling. The
    /// panel is what notices a drag, exactly as it notices those.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Flipped to match `PanelClickOverlay`, so a point converted from the window lands where the
    /// card is drawn.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            return
        }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .dragOutOfPanel, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let origin = note.userInfo?["locationInWindow"] as? NSPoint,
                  let event = note.userInfo?["event"] as? NSEvent
            else { return }
            let local = self.convert(origin, from: nil)
            guard self.bounds.contains(local) else { return }
            self.beginDrag(with: event)
        }
    }

    private func beginDrag(with event: NSEvent) {
        let plan = self.plan()
        guard !plan.items.isEmpty else { return }
        let writers: [NSPasteboardWriting]
        switch plan.kind {
        case .deferredPaste:
            // One item, one private type, no public representation: nothing will accept this drop,
            // which is what leaves the release free to mean "paste here".
            let pbItem = NSPasteboardItem()
            pbItem.setString(plan.items.map { $0.id.uuidString }.joined(separator: ","),
                             forType: DragPaste.deferredType)
            writers = [pbItem]
        case .native:
            writers = plan.items.map(Self.nativeWriter(for:))
        }

        let image = Self.snapshot(of: superview, badge: plan.items.count)
        let items = writers.map { writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(bounds, contents: image)
            return item
        }
        draggingPlan = plan
        beginDraggingSession(with: items, event: event, source: self)
        NotificationCenter.default.post(name: .panelDragBegan, object: nil)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let plan = draggingPlan else { return }
        draggingPlan = nil
        // A cancelled drag and a drop nobody accepted both arrive with an empty operation, so the
        // only discriminator is the event that ended the session. The test is positive — Escape and
        // nothing else — because the spike could not verify it by machine, and the two mistakes are
        // not equal: reading Escape as a release pastes something undoable, while reading a release
        // as Escape would make the feature look dead.
        let cancelled = NSApp.currentEvent?.type == .keyDown && NSApp.currentEvent?.keyCode == 53
        let shift = NSEvent.modifierFlags.contains(.shift)
        onEnded(plan, screenPoint, operation, shift, cancelled)
    }

    // MARK: - Payload and image

    /// What one item looks like on the dragging pasteboard when the target is meant to handle the
    /// drop itself: the real file where there is one, so Finder copies it and an upload zone
    /// receives it, and the picture or the link otherwise.
    static func nativeWriter(for item: ClipboardItem) -> NSPasteboardWriting {
        switch item.type {
        case .file, .folder:
            if let url = item.fileURLs?.first { return url as NSURL }
        case .image:
            if let url = ClipboardStore.shared.imageURL(for: item.id),
               FileManager.default.fileExists(atPath: url.path) {
                return url as NSURL
            }
            if let data = item.imageData, let image = NSImage(data: data) { return image }
        case .url:
            if let text = item.text, let url = URL(string: text) { return url as NSURL }
        case .text:
            break
        }
        return (item.text ?? item.displayText) as NSString
    }

    /// A picture of the card, so what is being dragged is what the user just pressed on.
    ///
    /// Rendered from the layer rather than with `cacheDisplay`: the card is SwiftUI's, drawn into a
    /// layer tree, and `cacheDisplay` comes back empty for those.
    static func snapshot(of view: NSView?, badge count: Int) -> NSImage? {
        guard let view, let layer = view.layer, view.bounds.width > 1 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: view.bounds.size)
        guard count > 1 else { return image }
        return withBadge(count, on: image)
    }

    /// How many cards are travelling, drawn into the corner of the drag image.
    private static func withBadge(_ count: Int, on image: NSImage) -> NSImage {
        let badged = NSImage(size: image.size)
        badged.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        let text = "\(count)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let diameter = max(size.width, size.height) + 12
        let circle = NSRect(x: image.size.width - diameter - 6,
                            y: image.size.height - diameter - 6,
                            width: diameter, height: diameter)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: circle).fill()
        text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2),
                  withAttributes: attrs)
        badged.unlockFocus()
        return badged
    }
}
```

- [ ] **Step 5: Wire it into `ContentView`**

In `horizontalList`, replace `.onDrag { dragProvider(for: item) }` with:

```swift
                            .overlay(CardDragSource(
                                plan: { dragPlan(for: item) },
                                onEnded: { plan, point, operation, shift, cancelled in
                                    finishDrag(plan, at: point, operation: operation,
                                               shiftHeld: shift, cancelled: cancelled)
                                }
                            ))
```

Make the identical replacement in `verticalList`.

Then delete `dragProvider(for:)` entirely — `CardDragSourceView.nativeWriter(for:)` replaces it —
and add beside `pasteItem`:

```swift
    /// What a drag out of the panel carries. Read at the moment the drag starts, so a selection
    /// changed since the card was built is the one that travels.
    private func dragPlan(for item: ClipboardItem) -> DragPaste.Plan {
        DragPaste.plan(dragging: item,
                       selection: selection.ids,
                       displayed: displayedItems,
                       accessibilityTrusted: accessibilityTrusted)
    }

    /// A drag has ended. Nothing has touched the pasteboard until this point, so a cancelled drag
    /// leaves the user's clipboard exactly as it was.
    private func finishDrag(_ plan: DragPaste.Plan, at point: NSPoint,
                            operation: NSDragOperation, shiftHeld: Bool, cancelled: Bool) {
        guard !cancelled else {
            NotificationCenter.default.post(name: .panelDragCancelled, object: nil)
            return
        }
        // The target took the drop and has already done the work — a file copied into Finder, a
        // picture dropped into an upload zone. Pasting on top of that would deliver it twice.
        if plan.kind == .native, !operation.isEmpty {
            reorderAfterDrag(plan)
            return
        }
        guard let content = DragPaste.content(
            for: plan,
            shiftHeld: shiftHeld,
            alwaysPlainText: UserDefaults.standard.bool(forKey: "alwaysPastePlainText"),
            separator: .stored()
        ) else { return }

        ClipboardMonitor.shared.markNextChangeAsOwn()
        switch content {
        case let .item(item):
            item.write(to: .general)
        case let .plain(text):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        var info: [String: Any] = [:]
        if let pid = DropTargetResolver.pid(under: point) { info["targetPID"] = pid }
        if let length = DragPaste.selectableLength(of: content) { info["selectLength"] = length }
        NotificationCenter.default.post(name: .pasteClipboardItem, object: nil, userInfo: info)
        reorderAfterDrag(plan)
    }

    /// Brings the dragged item back to the front of the history, which is what ⏎ and a
    /// double-click already do. The panel is hidden by now, so the store is not publishing and this
    /// costs no layout.
    private func reorderAfterDrag(_ plan: DragPaste.Plan) {
        guard let first = plan.items.first,
              let live = store.items.first(where: { $0.id == first.id }) else { return }
        store.moveToTop(live)
    }
```

- [ ] **Step 6: Build and run the whole suite**

```bash
cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug test 2>&1 | grep -E "error:|Test Suite 'All tests'|\*\* TEST"
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd /Users/pikalong/xPaste && git add -A && git commit -m "Carry a card to an application and paste it there"
```

---

### Task 6: Prove it end to end, and that nothing else moved

**Files:**
- Scratch only: the synthetic drag driver from Task 0, a scratch `.txt`, a small AX reader.

**Interfaces:**
- Consumes: everything above.
- Produces: measured evidence for the two behaviours the feature exists for, plus regression and
  perf figures.

- [ ] **Step 1: Build Release and burn in the binary**

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Release build 2>&1 | grep -cE "BUILD SUCCEEDED"
```

The first launch of a freshly built binary is polluted by dyld and signature checks; run it once
with `XPASTE_PERF=1 XPASTE_AUTOOPEN=2` and discard those numbers.

- [ ] **Step 2: Write the Accessibility reader for the target's text and selection**

```swift
// axread.swift — prints the focused element's value and its selected text, for a given pid.
import ApplicationServices
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let app = AXUIElementCreateApplication(pid)
var focused: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
      let element = focused as! AXUIElement? else { print("NOFOCUS"); exit(1) }
func string(_ attr: String) -> String {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attr as CFString, &out) == .success,
          let s = out as? String else { return "" }
    return s
}
print("VALUE:\(string(kAXValueAttribute as String))")
print("SELECTED:\(string(kAXSelectedTextAttribute as String))")
```

- [ ] **Step 3: Set up the target document and prove the selection is replaced**

Write a scratch file with known text, open it in TextEdit, select the middle word through AX, then
drive a drag from the first card onto the TextEdit window and read back:

```bash
S=/private/tmp/claude-501/-Users-pikalong/*/scratchpad
printf 'ALPHA REPLACEME OMEGA\n' > $S/target.txt
open -a TextEdit $S/target.txt
```

Select `REPLACEME` via AX (a `setSelectedRange`-style helper alongside `axread.swift`), then run the
app with `XPASTE_PERF=1 XPASTE_AUTOOPEN=1 XPASTE_DWELL=8`, and drag card 1 into the TextEdit window
with `dragger`. Then:

```bash
$S/axread $(pgrep -x TextEdit)
```

Expected: `VALUE:` contains `ALPHA <the card's text> OMEGA` — **`REPLACEME` is gone**, which is the
first of the two behaviours. If it instead reads `ALPHA REPLACEME<card text> OMEGA`, the paste went
in as an insertion and the feature has not worked.

- [ ] **Step 4: Prove the pasted text is left selected**

From the same run:

```bash
$S/axread $(pgrep -x TextEdit)
```

Expected: `SELECTED:` equals the card's text exactly — the second behaviour. Record both outputs.

- [ ] **Step 5: Check the panel's own clicks still work**

With the panel open (`XPASTE_DWELL=8`), replay the two safe gestures with the `clicker` built
earlier, screenshotting after each:

- a single click on card 3 — the selection ring must move to it
- a ⌘-click on card 5 — it must join the selection rather than replace it

Double-click is **not** automated: it pastes for real into whatever holds focus.

- [ ] **Step 6: Check a cancelled drag leaves the clipboard alone**

```bash
S=/private/tmp/claude-501/-Users-pikalong/*/scratchpad
osascript -e 'set the clipboard to "SENTINEL"'
# run the app, then: $S/dragger <card x> <card y> <target x> <target y> <delay> cancel
osascript -e 'the clipboard as text'
```

Expected: `SENTINEL`. The panel must also be back on screen.

- [ ] **Step 7: Re-measure the open path**

```bash
cd /Users/pikalong/xPaste && REL=~/Library/Developer/Xcode/DerivedData/xPaste-*/Build/Products/Release/xPaste.app/Contents/MacOS/xPaste
XPASTE_PERF=1 XPASTE_AUTOOPEN=8 XPASTE_COPIES=2 $REL >/dev/null 2>&1
/usr/bin/log show --predicate 'subsystem == "com.user.xPaste"' --last 45s --info | sed 's/.*perf\] //' | grep -E "=== open|main thread"
```

Expected: open totals within 19-32ms and `late(>12ms): 0` on every reveal — no worse than before the
feature. Each card now carries one more `NSView`, and `.onDrag` has been removed, so this may
improve.

- [ ] **Step 8: Commit the findings**

```bash
cd /Users/pikalong/xPaste && git commit --allow-empty -m "Record the drag-to-paste verification results"
```

---

## Self-review

**Spec coverage.** Text and links paste, images and files keep the native payload (Task 1's
`kind(for:)`, Task 5's `nativeWriter`). The release point picks the application (Task 3). The pasted
text is left selected (Tasks 2 and 4). The panel gets out of the way and comes back on a cancel
(Task 5 Step 3). Multi-selection drag, ⇧ for plain text, and the push to the top of history are all
in Task 1 and Task 5 Step 5. The no-Accessibility fallback is tested in Task 1. The two open risks
are settled in Task 0 before anything is built on them. Every error-handling row in the spec has a
home: no-Accessibility and mixed selections in Task 1, released-over-nothing in Task 3, native
payload nobody accepted and empty plans in Task 5, silent AX failure in Task 2.

**Not covered by automated tests, by decision:** the drag session itself, the AX write into another
application, and the drag image. Task 6 covers the first two by driving a real drag and reading the
result back out of TextEdit; the drag image is visible in Task 6's screenshots.

**Type consistency.** `DragPaste.Plan`, `PayloadKind`, `PasteContent` and the four `DragPaste`
functions are named identically in Tasks 1, 5 and 6. `AXTextSelection.selectPastedText(pid:length:)`
is called in Task 4 exactly as declared in Task 2. `DropTargetResolver.pid(under:)` is called in Task
5 exactly as declared in Task 3. The `userInfo` keys `"targetPID"`, `"selectLength"`,
`"locationInWindow"` and `"event"` are spelled the same at every producer and consumer.
