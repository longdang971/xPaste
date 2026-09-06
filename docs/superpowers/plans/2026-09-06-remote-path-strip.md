# Remote path stripping — implementation plan

**Goal:** A copied `sftp://10.0.0.5/home/pikalong/www` reaches the clipboard, and the history, as
`/home/pikalong/www`.

**Architecture:** A pure `RemotePath.strip(_:)` decides what a remote path reduces to;
`ClipboardMonitor.poll()` applies it to a captured text item, rewriting the system pasteboard
through the existing `writeOwned` handshake and replacing the item's payload so a paste from the
panel agrees with the card.

**Tech Stack:** Swift 5.9, Foundation (`URL`), AppKit (`NSPasteboard`), XCTest.

Spec: `docs/superpowers/specs/2026-09-06-remote-path-strip-design.md`

## Task 1 — `RemotePath.strip`

- [ ] Write `xPasteTests/RemotePathTests.swift` covering the spec's rule table: the four rewriting
      cases (plain, `user@host:port`, mixed-case scheme, `ftp`/`ftps`), percent-decoding to
      `/thư mục`, root `/`, and the five no-op cases (no path, `ssh`, `http`, URL inside prose,
      a string that is already a path). Plus multi-line: all-URL block strips, mixed block does not.
- [ ] Write `xPaste/Services/RemotePath.swift` to pass them.
- [ ] Add both files to the project (`xcodegen`) and run the suite.

## Task 2 — Rewriting on capture

- [ ] Extend `xPasteTests/ClipboardMonitorTests.swift`: after a remote URL is put on a scratch
      pasteboard and polled, (a) the pasteboard holds the stripped text, (b) the change is claimed
      so no duplicate item follows, (c) the stored item's `text` and `payload` both carry the
      stripped text and no representation of the original survives.
- [ ] Apply the rewrite in `ClipboardMonitor.poll()`, after `ClipboardItem.from(pasteboard:)` and
      before the `excludedPatterns` filter.
- [ ] Run the full suite.

## Global Constraints

- The rewrite touches only `.text` items. A `.url` (http/https), colour, image, file or folder item
  is passed through untouched.
- `poll()`'s early returns — ignored app, concealed, transient — keep precedence. They run first
  and the rewrite never sees those copies.
- No new user-facing setting, no `Paste as…` entry, no change to `TextTransform`.
