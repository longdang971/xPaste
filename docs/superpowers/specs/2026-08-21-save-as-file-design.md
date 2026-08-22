# Save as File — design

**Goal:** A card's right-click menu gains "Save as File…", which writes the item to disk through a
Save dialog whose name and extension are already filled in with a guess at what the content is —
`.php` for PHP, `.py` for Python, `.png` or `.jpg` for a picture, `.json` for JSON.

## Scope

Text, Link and Image items only, one card at a time.

File and Folder items are left out: they already *are* files on disk, and dragging a card into
Finder already copies them. A menu entry that duplicated that would be a second way to do one thing.

A multi-card selection saves the card the menu was opened on, not the selection. Saving several
items at once is a different dialog (`NSOpenPanel` for a directory) and a different naming problem
(collisions within one batch); it is not part of this.

## Architecture

Two new files, splitting the decision from the disk:

| File | Role |
| --- | --- |
| `Services/SaveFormat.swift` | Pure. `suggest(for:) -> SaveSuggestion`, carrying a base name, an extension and the bytes. No AppKit, no FileManager. |
| `Services/ItemFileWriter.swift` | Writes a `SaveSuggestion` to a URL. The one filesystem call. |

This is the shape `DragPaste`, `TextTransform`, `MultiPaste` and `SearchQuery` already have in this
codebase: every rule that can go quietly wrong lives in a value type with no framework underneath
it, so it is tested directly rather than through a dialog.

### Flow

```
cardMenu → "Save as File…"  →  post .saveItemToFile { itemID }
                                        ↓
AppDelegate:  hidePanel()  →  NSApp.activate  →  SaveFormat.suggest
              →  NSSavePanel  →  ItemFileWriter.write
```

The dialog is run from `AppDelegate` rather than from `ContentView` because the panel is a
`nonactivatingPanel` that never becomes key or main, and the app runs under
`NSApp.setActivationPolicy(.accessory)`. A save dialog needs the app activated first — the same
sequence `openSettings()` already performs. Posting a notification with the item's ID and letting
`AppDelegate` do the window work follows `.pasteClipboardItem`.

Hiding the panel first also settles the global mouse monitor, which would otherwise hide the panel
on the first click into the dialog.

## Choosing the extension

First match wins, most specific first.

**Parsed, so near-certain**

| Test | Extension |
| --- | --- |
| Trimmed text starts `{`/`[` and `JSONSerialization` accepts it | `.json` |
| Starts `<?xml` | `.xml` |
| Starts `<!DOCTYPE html` or `<html` | `.html` |
| Starts `<svg` | `.svg` |

JSON reuses `TextTransform.jsonObject` (its `private` is dropped) rather than growing a second JSON
parser: it already carries the 4 MB cap and the cheap first-character check.

**Shebang, so definitive**

`#!` on the first line, matched against the interpreter: `bash`/`sh`/`zsh` → `.sh`, `python` →
`.py`, `node` → `.js`, `ruby` → `.rb`, `perl` → `.pl`, `php` → `.php`.

**Language markers**

`<?php` → `.php` · `def …():` or `from X import` → `.py` · `import SwiftUI`/`import Foundation`
with `func`/`let` → `.swift` · `SELECT … FROM`, `CREATE TABLE`, `INSERT INTO` → `.sql` ·
`package main` with `func` → `.go` · `fn main()` or `let mut` → `.rs` · `#include <` → `.c`, or
`.cpp` when `std::` or `class` also appears · `public class` → `.java` · `function`/`const`/`=>`/
`require(` → `.js`, or `.ts` when `interface` or a `: Type` annotation appears · a `selector {
property: value; }` block → `.css` · `# Heading` or `[text](link)` → `.md` · several lines carrying
the same number of commas → `.csv`.

**Anything else → `.txt`.**

A wrong guess costs the user a correction; `.txt` costs nothing and is true in the literal sense.
That asymmetry is why the fallback is `.txt` and not a best effort.

### Images

The extension is read from the bytes, not assumed: `89 50 4E 47` → `.png`, `FF D8 FF` → `.jpg`.

This matters because `NSImage.compressedData(maxBytes:)` stores PNG for an image that uses its alpha
channel and JPEG for everything else, while `ClipboardStore` names every one of them `.jpg` on disk.
The stored name is not evidence.

The bytes are written through unchanged. Re-encoding a JPEG as PNG bakes in the artefacts it
already has and makes the file several times larger for nothing.

### Links

`.html`, holding the page itself. The link is fetched when the user has already chosen where the
file goes, so the one slow step happens after every decision has been made and can report failure
without having wasted anything.

What lands is the markup as served — no images, no stylesheets, no script results. A page that
builds itself in the browser saves as the shell it was served as. Superseded the original `.webloc`,
which saved a pointer rather than the thing itself.

## Choosing the name

The dialog proposes **no name at all** — just `.php`, `.py`, `.json`. `NSSavePanel` selects the
base-name portion of what it is given, and an empty one leaves the insertion point in front of the
dot, which is where the user is about to type.

Names derived from the content read badly far more often than they helped: a PHP snippet proposed
itself as `<?php.php`, a Python one as `from dataclasses import dataclass.py`. Accepting the
proposal untouched would write a file called `.php` — nameless and hidden — so anything that
amounts to no name gets `Clipboard`.

A *dragged* file still takes a derived name, because nobody is offered a field to type one into:
the item's own name if it has one, otherwise its first line, its host, or `Image 2026-08-21 at
14.32.05` for a picture. Sanitising drops `/` and `:`, strips control characters and leading dots,
collapses whitespace, and bounds the result in UTF-8 bytes rather than characters.

## The dialog

`nameFieldStringValue` is the extension alone — see "Choosing the name".

For text and links `allowsOtherFileTypes` is set, so any extension can be typed over the suggestion.
For text the extension is only a label — the bytes are the same UTF-8 either way — so there is
nothing to protect.

For images `allowedContentTypes` is locked to the format the bytes actually are, so the dialog
cannot produce a `.png` holding JPEG.

**⌘S** triggers the same action for the selected card. It is handled in `AppDelegate`'s existing key
monitor, beside `⌘,` and `⌘1–9`, rather than as a hidden SwiftUI `Button`: establishing first
responder resolves every registered key equivalent, which is why eighteen of those were moved out of
the panel in the first place.

## Errors

- Write fails (permissions, full disk) — `NSAlert` carrying the real error
- An image whose bytes are gone from disk (the item was pruned) — its own alert, and no empty file
- Cancel — nothing happens
- Success — silence. The user picked the location; revealing it in Finder tells them what they
  already know.

## Testing

`SaveFormatTests`, pure, no filesystem:

- each language marker resolves to its extension
- prose, and code in a language with no rule, resolve to `.txt`
- a shebang beats a language marker that also matches
- PNG and JPEG magic bytes resolve to `.png` and `.jpg`
- the dialog proposes the extension and no name, even for an item the user has named
- a proposal accepted untouched still gets a name rather than writing a hidden `.php`
- a dragged file, which has no dialog, still takes a derived and sanitised name — bounded in UTF-8
  bytes rather than characters
- a link resolves to `.html`

`ItemFileWriterTests` writes into a temporary directory and reads the bytes back, including a page
resolved from a `file://` URL (so the fetch is exercised without a network), a page that was never
fetched, and the "image bytes are gone" failure.
