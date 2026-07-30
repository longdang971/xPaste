# Show a card's real formatting

Date: 2026-07-30

## Problem

Copy white-on-black text — a terminal transcript, a snippet from a dark editor — and xPaste's
card draws it as plain black text on a white fill. Paste it and the black background comes back,
because `ClipboardItem.write(to:)` puts the captured RTF on the pasteboard. The card and the
paste disagree, so the card misleads: nothing on it says the content carries styling at all.

The data is already there. `ClipboardItem` captures `richData` (RTF, falling back to HTML) plus
`richType` in `captureRich(from:)`, persists both through `CodingKeys`, and writes `richData`
first on paste. Only the drawing layer ignores it: `ClipboardItemCard.textPreview` is a
`Text(cardText.preview)` over `Color(NSColor.textBackgroundColor)`, and
`PreviewPopoverContent.textContent` is the same plain `Text`.

## What Paste does

Paste renders the styling faithfully. Three items were copied and photographed in Paste's panel;
each row below is read off that screenshot.

| Behaviour | Evidence |
| --- | --- |
| The fill covers the whole content area, not just the glyph runs | Cards 1 and 2 are black out to the right of every short line |
| The footer takes the same fill | "84 characters" / "78 characters" sit on black with light grey text |
| The fill is derived from the runs, not from document attributes | The fixtures set **no** document background, only per-run backgrounds, and Paste still filled the card |
| Font family and size survive | "REAL APP COPY" is large bold and wraps to two lines; terminal lines stay monospaced |
| Foreground colours survive | `On branch main` green, `$ echo done` yellow, "underlined link-ish" purple + underline |
| A highlight stays a highlight | "highlighted yellow text" is a yellow box hugging its run, not a card-wide fill |
| The header keeps the source app's colour | Grey for TextEdit, near-black for Terminal — unchanged from xPaste today |

The three fixtures also pin down how the fill is chosen. Counting characters per run background:

| Fixture | Run backgrounds | Paste's fill |
| --- | --- | --- |
| Terminal transcript | 78 / 78 black | black |
| TextEdit document | 49 black, 21 yellow, 14 none (of 84) | black |
| Mixed styles | 55 none, 24 yellow (of 79) | default white, yellow only behind its run |

**Rule:** the run background covering the most characters becomes the card's fill; when "no
background" covers the most, the card keeps its default fill. All three fixtures agree.

## Non-goals

- No change to capture or to paste. `captureRich` and `write(to:)` stay exactly as they are.
- No RTFD, so no inline images or attachments — they are not on the pasteboard we capture.
- No text selection inside a card. A card is a tile you click to paste.
- No settings toggle. Faithful rendering is the behaviour, not an option.
- No restyling of the header, the hover actions, the shortcut badge, or the link preview.

## Architecture

### `xPaste/Services/RichTextRenderer.swift` (new)

One place that knows how to turn `richData` into something drawable. Card and popover share it,
so they cannot drift apart, and every rule below is a pure function that tests can call without
building a view.

```swift
/// A card's rich preview. `image == nil` is the decision to draw plain text instead — a negative
/// result worth caching, so an item that resolved to plain is never parsed twice.
final class RichCardPreview {
    let image: NSImage?
    /// nil means "use NSColor.textBackgroundColor".
    let fill: NSColor?
}

/// A parsed `richData`. A class, not a tuple, so it can cross the detached-parse boundary
/// without a Sendable warning — `NSAttributedString` is not Sendable.
final class ParsedRich: @unchecked Sendable {
    let text: NSAttributedString
    let documentBackground: NSColor?
}

enum RichTextRenderer {
    /// Parses `richData` per `richType`. nil when the item has no `richData`, its type is
    /// unrecognised, or it is over the size cap — so only `.text` and `.url` items can ever
    /// produce a result.
    static func parse(_ item: ClipboardItem) -> ParsedRich?

    /// The run background covering the most characters. nil when "no background" covers the most.
    static func dominantBackground(of text: NSAttributedString) -> NSColor?

    /// The composition point for the two background sources, so the precedence between them is
    /// testable without depending on what an RTF/HTML round-trip happens to preserve.
    static func resolveFill(runBackground: NSColor?, documentBackground: NSColor?) -> NSColor?

    /// False when the text would be near-invisible on `fill` — see "The blank-card guard".
    static func isLegible(_ text: NSAttributedString, on fill: NSColor) -> Bool

    /// Always returns a decision, never nil: a rasterised preview, or `image == nil` meaning
    /// "draw plain text". The caller caches the result either way.
    static func cardPreview(for item: ClipboardItem, size: CGSize,
                            defaultFill: NSColor) async -> RichCardPreview

    /// The full string plus its fill, for the popover. nil to fall back to plain text.
    static func fullPreview(for item: ClipboardItem, defaultFill: NSColor) -> RichFullPreview?
}
```

`defaultFill` defaults to `NSColor.textBackgroundColor` and the app never passes anything else.
It exists because that colour resolves against the current appearance, which would otherwise make
the legibility guard — and every test that exercises it — depend on whether the machine is in
light or dark mode. Tests pass a fixed colour.

### Size caps

Parsing is bounded before it starts, because both importers can be slow on large input:

- RTF: skip when `richData.count > 4_000_000`.
- HTML: skip when `richData.count > 262_144`. The cap is far lower because
  `NSAttributedString(html:)` is a WebKit importer that **must run on the main thread**, so its
  cost lands on the panel. RTF is the common case anyway — `captureRich` prefers it, and the
  apps that supply HTML almost always supply RTF too.

Over the cap, `cardPreview` yields `image == nil` and the card draws plain text as it does today.

### Choosing the fill

1. `dominantBackground(of:)` — winner by character count across run backgrounds.
2. If that is nil, use the document background from `parse` (an RTF `\viewbkcol`), if present.
3. If that is nil too, the fill is nil and the card keeps `NSColor.textBackgroundColor`.

Backgrounds are compared in `deviceRGB` and rounded to 3 decimals per component before being
tallied, so two runs whose colours differ only by colour-space round-tripping count as one.

### The blank-card guard

The TextEdit fixture proves the risk is real: its red 26pt heading carries **no** background of
its own, and only survives because the rest of the string dragged the fill to black. A source
that hands over light text with no background anywhere would otherwise rasterise to a blank card
— worse than today.

So when the fill resolves to nil (default) **and** `isLegible` finds the foreground colour
covering the most characters has a contrast ratio below 1.5:1 against `textBackgroundColor`,
`cardPreview` yields `image == nil` and the card draws plain text. None of the three fixtures
hits this; it exists only to stop a blank card.

## Card rendering

`ClipboardItemCard` draws the preview **once** into a bitmap and reuses it:

- A static `NSCache<NSUUID, RichCardPreview>` on `ClipboardItemCard`, `countLimit = 120`, sitting
  alongside the existing `pathImageCache` / `loadedImageCache` and following the same pattern.
  One cache holds both outcomes, so an item that resolved to plain is never re-parsed when it
  scrolls back into view.
- `.task(id: item.id)` populates it; `body` only reads it. RTF parsing runs in a
  `Task.detached`; HTML parsing and the rasterisation run on the main actor, because both use
  TextKit/WebKit.
- The bitmap is produced with `lockFocusFlipped(true)` on a plain `NSImage`, which gives retina
  backing from the display and flipped coordinates so text flows downward from the top of the
  rect. A drawing-handler `NSImage` would instead re-run TextKit on every draw and defeat the
  whole point.
- The string is truncated to 1500 characters before layout, and drawn with
  `.usesLineFragmentOrigin` + `.truncatesLastVisibleLine` inside the content rect, inset 12pt to
  match the current `textPreview` padding.

This ordering is what keeps the panel fast. Speed is the project's first priority: TextKit runs
once per item per session, and every later body pass is a plain `Image(nsImage:)`. Handing an
`AttributedString` to SwiftUI's `Text` instead would make TextKit re-measure on every re-layout,
for every visible card in the `LazyHStack` — the exact trap that cost ~120ms per re-layout when
each card eagerly built its share menu.

### Where it slots in

`contentPreview`'s precedence is unchanged: detected file path → detected colour → **rich** →
plain. The specialised previews stay ahead of it, so a copied `#000000` still shows its swatch.
`.url` items are unchanged too — link preview first, and rich only reaches the `textPreview`
branch that already exists.

`defaultFooter` and `urlPreviewFooter` take the same fill when one was resolved, and their text
switches between dark and light through the existing `isLightColor(_:)` helper. `fileFooter` is
untouched, since a path item never renders rich.

## Popover rendering

`PreviewPopoverContent.textContent` becomes an `NSViewRepresentable` over a read-only
`NSTextView` in an `NSScrollView`: `isEditable = false`, `isSelectable = true`,
`drawsBackground = true`, `backgroundColor` set to the resolved fill, 14pt text container inset.
It renders the **full** string from `fullPreview`, not the 1500-character truncation.

TextKit direct rather than a bitmap here: fidelity and text selection matter more than speed,
and only one popover exists at a time. When `fullPreview` returns nil, the existing plain `Text`
stays.

The popover's footer keeps its plain character/word/line count.

## Testing

`xPasteTests/RichTextRendererTests.swift`, with fixtures built in code the same way the
observed items were — attributed string → `rtf(from:documentAttributes:)` → `ClipboardItem`:

| Test | Assertion |
| --- | --- |
| Terminal fixture | `dominantBackground` is black |
| TextEdit fixture (49 black / 21 yellow / 14 none) | `dominantBackground` is black — majority, not unanimity |
| Mixed fixture (55 none / 24 yellow) | `dominantBackground` is nil |
| `resolveFill` with a nil run background | falls through to the document colour |
| `resolveFill` with both present | the run background wins |
| HTML fixture with a run background | parses, and that background is found |
| Item with no `richData` | `parse` returns nil |
| RTF over 4 MB, HTML over 256 KB | `cardPreview` returns nil |
| White foreground, no background anywhere | `isLegible` false, `cardPreview` nil |
| Terminal fixture rasterised | image is non-nil, matches the requested point size, and a pixel in the padding is black — proof the fill reaches the bitmap |

Existing suites must keep passing untouched, `ClipboardItemTests` in particular: capture and
paste behaviour is explicitly out of scope, so any change there means something went wrong.

## Performance verification

The panel's open path is 16–25ms after the July 2026 work and must stay there. Before and after
the change, run the existing harness and compare:

```
XPASTE_PERF=1 XPASTE_AUTOOPEN=5 XPASTE_COPIES=3 \
  ~/Library/Developer/Xcode/DerivedData/xPaste-gzzhgdrvluhlbkbridqtxdsusbnr/Build/Products/Debug/xPaste.app/Contents/MacOS/xPaste
/usr/bin/log show --predicate 'subsystem == "com.user.xPaste"' --last 30s --info
```

The injected items are plain, so a first run measures that nothing regressed for plain text. A
second measurement with rich items in history covers the parse-and-rasterise path. If open time
moves outside the band, the fix is to shrink the character limit or the caps, not to accept it.

## Accepted consequences

- A card with formatting no longer follows light/dark mode; it keeps the source's colours. That
  is the point — and Paste behaves the same way.
- Font size is preserved, so copying a 28pt heading yields a card with large text and few lines.
  Scaling it down would distort the very thing being shown faithfully.
