# Drag a card out to paste it

## The problem

Dragging a card out of the panel today is a plain SwiftUI `.onDrag` handing an `NSItemProvider` to
whatever is underneath. SwiftUI owns the session, so xPaste never learns where the drop landed and
cannot influence it. Two consequences the user hit:

- Dropping onto a **selection** does not replace it. The target inserts at its own drop point, which
  is the target's decision, not ours.
- The dropped text is **not left selected** afterwards, so it cannot be typed over straight away.

Neither is fixable through drag-and-drop: both belong to the app receiving the drop. To get them the
gesture has to end in a real paste, because a paste is what replaces a selection, and only then is
there an insertion whose range we can go on to select.

A third annoyance, found while reading the code: the panel stays open for the whole drag, so it
covers the bottom strip of the screen you might want to drop onto, and it is still open afterwards.

## What we are building

A drag out of the panel becomes **"carry this item to an app and paste it there"**.

- **Text and link items** paste. The release point picks the *application*; `⌘V` then lands wherever
  that app's caret or selection already is. That is exactly the case the user described — select a
  passage, drag an item onto that app, the passage is replaced — but it is a real difference from a
  true drop, which inserts at the point you released. We deliberately do **not** click at the
  release point to place the caret: the click would destroy the very selection being replaced.
- **Image, file and folder items** keep the real drag payload they have today. Drag-and-drop is the
  only way into a web upload zone or a Finder window, and `⌘V` is no substitute.
- After a drag-paste, the inserted text is **left selected**, via the Accessibility API.
- The panel **gets out of the way** when the drag leaves it, and comes back if the drag is cancelled.

Also in scope, because each is a small piece of the same gesture:

- Dragging a card that belongs to a multi-selection drags **all** of them, joined with the separator
  from Settings.
- Holding **⇧** on release pastes as plain text, mirroring `⇧⏎` and `⇧⌘1-9`.
- The dragged item is **pushed to the top of history**, which `⏎` and double-click already do and
  drag did not.

### Out of scope

- Selecting the pasted text after a *keyboard* paste (`⏎`, double-click, `⌘1-9`). Those keep today's
  behaviour so existing muscle memory is untouched.
- Placing the caret at the release point.
- Dragging text into Finder to make a `.textClipping`. Lost by choice, in exchange for the paste
  semantics above.

## Architecture

Four new files, each with a single purpose, so the parts that hold the rules can be tested apart
from the parts that touch AppKit:

| File | Purpose | Tested |
|---|---|---|
| `Services/DragPaste.swift` | Pure decisions: which items a drag carries, which payload kind they need, what text gets written, how long it is | unit |
| `Views/CardDragSource.swift` | The AppKit drag session: start it, supply the drag image, watch for Escape, report where it ended | manually |
| `Services/DropTargetResolver.swift` | A screen point to the pid of the application under it, ignoring xPaste's own windows | manually |
| `Services/AXTextSelection.swift` | Select the text just pasted, over the Accessibility API. The range arithmetic is a separate pure function | arithmetic: unit |

`ContentView` is already 1370 lines and doing plenty; none of this logic goes into it. It only swaps
`.onDrag { dragProvider(for: item) }` for `.overlay(CardDragSource(...))` in both list layouts and
hands over the closures. `dragProvider` stays as it is, now used only for the real payloads.

Three small changes to existing code, each following a pattern the codebase already uses:

- **`ClipboardPanel.sendEvent`** already intercepts `leftMouseDown` to route ⌘-click and
  double-click. It gains drag detection: remember the press, and once `leftMouseDragged` passes the
  threshold, post `.dragOutOfPanel`. Cards pick it up by testing whether the point is inside them,
  exactly as `cmdClickInPanel` and `doubleClickInPanel` already work.
- **`AppDelegate.handlePasteItem`** already does "check Accessibility, hide the panel, activate the
  target, post ⌘V to its pid". It gains two optional values in `userInfo`: `targetPID`, used instead
  of `previousApp`, and `selectLength`, which asks for the selection pass afterwards. No paste path
  is rewritten.
- **Two notifications** beside the existing ones: `.panelDragBegan` (AppDelegate hides the panel) and
  `.panelDragCancelled` (it comes back).

## Data flow

### Starting the drag

1. `ClipboardPanel` sees `leftMouseDragged` more than **6pt** from a press that carried no ⌘ and had
   `clickCount == 1`, and posts `.dragOutOfPanel` carrying the **original press point**, not the
   current one, so the right card is identified after the pointer has already moved.
2. The card containing that point asks for a plan: if it belongs to the current multi-selection, the
   plan is every selected item **in panel order**; otherwise just itself.
3. Payload kind:
   - **Deferred** — every item is text or a link **and** Accessibility is granted: one
     `NSPasteboardItem` carrying only `com.user.xPaste.deferred-paste`. No public type, so no
     application accepts the drop and nothing is inserted anywhere.
   - **Native** — anything else: today's payload from `dragProvider`.
4. The drag image is a snapshot of the card, with a count drawn on it when the plan carries more
   than one item.
5. The session begins; `.panelDragBegan` sends the panel away; a local key monitor watches for
   Escape.

### Ending it

`draggingSession(_:endedAt:operation:)` decides between three outcomes:

- **Escape was pressed** → post `.panelDragCancelled`, the panel returns, nothing else happens.
- **Native payload and the target accepted it** (`operation != []`) → the target has done the work.
  Push the item to the top of history and stop.
- **Anything else** → paste:
  1. `DropTargetResolver` finds the pid under the release point; failing that, fall back to the app
     that was frontmost when the panel opened, which is almost always the intended one.
  2. Pick the text: ⇧ held means plain text; otherwise the same rule `pasteItem` already applies,
     including honouring the "always paste as plain text" setting. A multi-item plan is always
     joined plain text.
  3. `ClipboardMonitor.markNextChangeAsOwn()`, write the pasteboard, post `.pasteClipboardItem` with
     `targetPID` and `selectLength`.
  4. Push the item to the top of history.

**Ordering matters:** the pasteboard is written only after the drag has ended, so a cancelled drag
can never disturb the user's clipboard.

### Selecting what was pasted

`AppDelegate` posts ⌘V as it does today. When `selectLength` is present, ~90ms later:

1. `AXUIElementCreateApplication(pid)` → `kAXFocusedUIElementAttribute`.
2. Read `kAXSelectedTextRangeAttribute`: after a paste it is a caret of length 0 at some position P.
3. `AXTextSelection.rangeCoveringInsertion(caretAt: P, length: N)` → `{max(0, P - N), min(N, P)}`,
   which is the pure, tested part.
4. Write it back.

`N` is the UTF-16 length of the plain text written to the pasteboard. For a rich item the visible
character count is the same, which is what the target inserted.

## Error handling

| Situation | Behaviour |
|---|---|
| Accessibility not granted | Text items fall back to the **native** payload, so dragging still works exactly as it does today. No permission prompt in the middle of a drag. |
| Released over xPaste itself (e.g. the Settings window) | Treated as a cancel |
| No application under the release point (menu bar, Dock, bare desktop) | Fall back to the app that was frontmost when the panel opened |
| Image or file that nobody accepted | Paste it: an image goes into Preview or Keynote, a file into Finder |
| The card was deleted mid-drag | Empty plan, nothing happens |
| Multi-item plan with ⇧ | Still joined plain text — "rich" has no meaning for a group |
| Selecting the pasted text fails (Chrome, Electron, anything that refuses the AX write) | Silent. The caret stays at the end, as after any paste. No error, no retry. |

## What the spike settled

The panel is ordered out **while the session is running**, and the session was begun from a view
inside that window, so the first question was whether AppKit cancels a drag whose source window
disappears. A throwaway drag source, driven by a synthetic drag, answered it: `movedTo` callbacks
keep arriving all the way to the release point after the window has been ordered out. **Hiding the
panel is safe**, and the `alphaValue = 0` fallback is not needed.

The same spike found something that changes how a cancel is detected and how this gets verified: **a
`CGEvent`-synthesised release does not end a dragging session.** The session follows synthetic
`leftMouseDragged` events faithfully — the `movedTo` points traced the injected path exactly — but
neither a synthetic `leftMouseUp` (on either event tap, with or without `mouseEventClickState`) nor a
synthetic Escape ever produced `draggingSession(_:endedAt:operation:)`. Only a physical button
release ends it.

Two consequences:

- **Cancel detection is defensive.** A cancelled drag and a drop nobody accepted both arrive as
  `operation == []`, so the discriminator is `NSApp.currentEvent`. Since that could not be verified by
  machine, the test is *positive*: a cancel is `keyDown` with keyCode 53 and nothing else. Every other
  case pastes. The asymmetry is deliberate — mistaking Escape for a release pastes something the user
  can undo, while mistaking a release for Escape would make the whole feature look dead.
- **The gesture cannot be verified end to end automatically.** What can be, and is: the entire tail
  of the pipeline, from "a drag ended at this point" through target resolution, the pasteboard write,
  `⌘V` and the selection pass. A debug hook (`XPASTE_DRAGEND`, env-gated exactly like the existing
  `XPASTE_AUTOOPEN` harness) calls the end-of-drag handler directly with a screen point. The drag
  gesture itself — press, threshold, drag image, session start — is left to the manual checklist,
  with the spike's evidence that a session starts and tracks correctly.

## Verification

**Unit tests** cover the pure rules: which items a plan carries (outside the selection, inside a
multi-selection, a selection of one, a deleted card); the payload-kind decision including the
no-Accessibility fallback; the text rule (⇧, the always-plain setting, a joined group); the drag
threshold; and `rangeCoveringInsertion` including a caret shorter than the insertion, which must
clamp to 0 rather than produce a negative range.

**End-to-end, with a synthetic drag.** The Release build in DerivedData is Accessibility-trusted, so
a real drag can be driven with `CGEvent` (mouseDown, a run of mouseDragged, mouseUp) into a scratch
`.txt` opened in TextEdit — in the scratch directory, touching nothing of the user's. With a
selection made through AX beforehand, two reads settle the two complaints by machine rather than by
eye:

1. Read the text back: the selected passage was **replaced**, not appended to.
2. Read `kAXSelectedText` of the focused element: the pasted text **is selected**.

**Regression cover**, because `sendEvent` handles every mouse event in the panel: replay a single
click (must select a card) and a ⌘-click (must toggle it) with the synthetic clicker. Double-click is
left to the user — it pastes for real into whatever has focus.

**Performance**, because each card gains an overlay view: re-measure the open path with the
`XPASTE_PERF=1` harness against the figures just achieved — 19-32ms to open, zero dropped frames.
Removing `.onDrag` takes a SwiftUI gesture layer away, so this may improve; the requirement is that
it must not get worse.

**Left to the user**, being unsafe or impossible to automate: dragging text into Chrome or an
Electron app to see whether the selection pass takes; dragging an image onto a web upload zone;
dragging a file into Finder; a multi-item drag; ⇧ on release; Escape mid-drag leaving the clipboard
untouched; and the left, right and top panel positions.
