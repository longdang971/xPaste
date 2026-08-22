# Save as File — Implementation Plan

**Goal:** A card's right-click menu gains "Save as File…", writing the item to disk through a Save
dialog whose name and extension are pre-filled with a guess at what the content is.

**Design:** `docs/superpowers/specs/2026-08-21-save-as-file-design.md`

**Architecture:** A pure `SaveFormat` decides the name, the extension and the bytes; a thin
`ItemFileWriter` puts them on disk; `AppDelegate` runs the dialog because the panel never becomes
key. Nothing about the decision touches AppKit, so every rule is tested directly.

**Tech Stack:** Swift 5.9, AppKit (`NSSavePanel`, `UTType`), SwiftUI, XCTest

**Order:** the pure decision first, tested to exhaustion; then the writer; then the wiring, which is
the only part that cannot be tested by machine.

---

## Task 1 — `SaveFormat`: the shape of a suggestion

- [x] `SaveSuggestion` value type: `baseName: String`, `ext: String`, `payload: Payload`
- [x] `Payload` is `.text(String)` / `.data(Data)` / `.weblocURL(URL)` / `.unavailable`
- [x] `SaveFormat.suggest(for: ClipboardItem, imageBytes: Data?) -> SaveSuggestion`
      — image bytes injected so the decision stays pure and testable without `ClipboardStore`
- [x] `suggestion.fileName` returns `"\(baseName).\(ext)"`

**Tests:** a text item yields `.text`, an image yields `.data`, a link yields `.weblocURL`; an image
whose bytes are nil yields `.unavailable`.

## Task 2 — Extension from parsed structure

- [x] Drop `private` from `TextTransform.jsonObject` so JSON is detected by the existing parser
- [x] `.json` for text that parses as JSON
- [x] `.xml` / `.html` / `.svg` from the opening tag

**Tests:** `{"a":1}` → `.json`; `{ not json` → not `.json`; `<?xml …` → `.xml`;
`<!DOCTYPE html>` and `<html>` → `.html`; `<svg …` → `.svg`.

## Task 3 — Extension from a shebang

- [x] Parse the first line when it starts `#!`, match the interpreter name anywhere in it
- [x] `bash`/`sh`/`zsh` → `.sh`, `python` → `.py`, `node` → `.js`, `ruby` → `.rb`, `perl` → `.pl`,
      `php` → `.php`

**Tests:** `#!/usr/bin/env python3` → `.py`; `#!/bin/bash` → `.sh`; an unknown interpreter falls
through to the language rules rather than resolving to `.sh`.

## Task 4 — Extension from language markers

- [x] `.php`, `.py`, `.swift`, `.sql`, `.go`, `.rs`, `.c`/`.cpp`, `.java`, `.js`/`.ts`, `.css`,
      `.md`, `.csv` per the design's table
- [x] Everything unmatched → `.txt`

**Tests:** one per language, using a realistic snippet rather than the marker alone; English prose →
`.txt`; a shebang beats a language marker that also matches (`#!/bin/bash` over a line containing
`function`).

## Task 5 — Extension from image magic bytes

- [x] `89 50 4E 47 0D 0A 1A 0A` → `.png`, `FF D8 FF` → `.jpg`, otherwise `.png`
- [x] Never trust the stored `.jpg` filename — `compressedData` writes PNG for transparent images

**Tests:** PNG magic → `.png`; JPEG magic → `.jpg`; a short/garbage buffer does not crash.

## Task 6 — Base names

- [x] `item.label` wins when it is non-blank
- [x] Text → first non-blank line, cut to 60 characters
- [x] Link → host
- [x] Image → `Image <yyyy-MM-dd> at <HH.mm.ss>` from `item.timestamp`
- [x] Sanitise: drop `/` and `:`, strip control characters and leading dots, collapse whitespace
- [x] A name that sanitises to nothing → `Clipboard`

**Tests:** a label beats a derived name; `a/b:c` sanitises; a 200-character line is cut to 60; a
line of only slashes yields `Clipboard`; a multi-line item takes its first non-blank line.

## Task 7 — `ItemFileWriter`

- [x] `write(_ suggestion: SaveSuggestion, to url: URL) throws`
- [x] `.text` → UTF-8, `.data` → verbatim, `.weblocURL` → a binary plist `["URL": string]`
- [x] `.unavailable` throws a named error

**Tests:** each payload round-trips out of a temporary directory; the `.webloc` reads back as a
plist whose `URL` key is the link; `.unavailable` throws.

## Task 8 — Menu entry and notification

- [x] `Notification.Name.saveItemToFile`
- [x] `ClosureMenuItem(title: "Save as File…", symbol: "square.and.arrow.down", key: "s",
      modifiers: .command)` in `ContentView.cardMenu`, for `.text` / `.url` / `.image` only
- [x] Posts the item's ID

## Task 9 — The dialog in `AppDelegate`

- [x] Observe `.saveItemToFile`: hide the panel, `NSApp.activate`, look the item up in the store
- [x] Load image bytes from `item.imageData` or `ClipboardStore.imageURL(for:)`
- [x] `NSSavePanel` with `nameFieldStringValue` pre-filled; `allowedContentTypes` locked for images,
      `allowsOtherFileTypes` for text and links
- [x] Write on OK; `NSAlert` carrying the real error on failure

## Task 10 — ⌘S

- [x] In `AppDelegate`'s key monitor, beside `⌘,`: post `.saveSelectedItem`
- [x] `ContentView` resolves the primary selection and posts `.saveItemToFile`
- [x] Suppressed while a card's name is being edited, via the `alertIsPresented` handshake that
      already guards `⌘,` and `⌘1–9`

  Not suppressed while the search field has focus, which is how `⌘1–9` already behave: nothing in a
  text field claims `⌘S`, and gating one shortcut differently from its neighbours would be the
  surprise, not the fix.

## Task 11 — Verify

- [x] `xcodegen generate` picks up the new files
- [x] `xcodebuild test -scheme xPaste -destination 'platform=macOS'` — 356 tests, 0 failures. The
      two linker warnings about XCTest's deployment target are the project's own and predate this
      work.
- [ ] **Still to do — manual.** The dialog is modal AppKit and cannot be driven by machine, so
      nothing below has been exercised yet:
  - the menu entry appears on a Text/Link/Image card and not on a File/Folder one
  - ⌘S with a card selected opens the same dialog
  - a PHP snippet arrives pre-filled as `<something>.php`, a screenshot as `.png`/`.jpg`
  - the saved `.webloc` opens the page on a double-click
  - the panel is properly hidden behind the dialog, and comes back cleanly after Cancel
