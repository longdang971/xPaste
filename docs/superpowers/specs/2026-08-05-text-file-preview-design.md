# Text file previews — design

**Date:** 2026-08-05

A copied file that turns out to be readable text shows its contents, both on the card and in the
Space-bar popover, instead of the generic document icon macOS hands back for anything it has no
thumbnail for. A `key.json` card currently looks exactly like a `notes.txt` card.

## Detecting a text file

Sniffed from the bytes, not from the extension or the system's type registry:

- `UTType` conformance skips files with no extension (`.env`, `Dockerfile`, `LICENSE`) and depends
  on which apps have registered which extensions — the same file can read as text on one Mac and
  not on another.
- A fixed extension list needs a code change per extension and always misses some.

The rule: read the first 8KB; if it contains no `0x00` byte and decodes as UTF-8, it is text. PDFs,
Office documents and archives all carry NUL bytes in their first few kilobytes, so they fall out on
their own.

### The truncation trap

Cutting at exactly 8192 bytes can land in the middle of a multi-byte UTF-8 sequence, and
`String(data:encoding:.utf8)` then returns nil for the *whole* block. Vietnamese text is 2–3 bytes
per accented character, so this is common rather than an edge case: without handling it, files
would fail to preview at random depending on their content. The decoder walks back up to 3 bytes to
a character boundary before decoding.

## Components

### `TextFileReader` (new service)

```swift
static func isProbablyText(_ data: Data) -> Bool   // no NUL byte
static func decode(_ data: Data) -> String?        // UTF-8, trailing partial sequence trimmed
static func read(_ url: URL, maxBytes: Int) -> String?
```

Split this way so the two rules are testable against `Data` literals without touching the disk.
`read` is the only part that does I/O.

Callers choose their own budget: the card reads 8KB (it displays a few hundred characters), the
popover reads 256KB (it scrolls).

### `ClipboardItemCard`

- `@State fileText` plus a `NSCache<NSUUID, NSString>` bounded at 120, matching `pathImageCache`.
- Read in `.task` via `Task.detached`, never in `body` — the existing caches all exist because
  per-body-pass work stutters panel layout.
- The draw decision is a static function so the preview and any other caller cannot disagree.
- Only when the item holds **exactly one** file. Showing the first file's contents for a
  three-file item is a wrong answer that looks like a right one.
- Image files keep the existing thumbnail path; that check already runs first.

The text stops above the footer rather than flowing under it. Text cards flow because they have
`bottomFade`; enabling that here means changing `contentFlowsUnderFooter`, which also governs
`.text` items that hold a path. Not worth the blast radius for the fade alone — revisit separately
if the hard edge reads as cropped.

### `PreviewPopoverContent`

`fileContent` keeps its icon + name + Reveal row and gains a scrollable text pane beneath it.

## Out of scope

- No Settings toggle. A file's contents show whenever they are readable; hiding one means deleting
  the item. (Explicitly considered and declined — it is worth knowing that this puts the contents
  of a copied credentials file on screen.)
- Folders are not read.
- No syntax highlighting.

## Testing

`TextFileReader` carries the risk, so it carries the tests: NUL rejection, valid UTF-8, invalid
byte sequences, **a Vietnamese string cut mid-character at the byte cap**, an empty file, and a
file larger than the cap. Plus the card's draw decision, including the one-file rule.
