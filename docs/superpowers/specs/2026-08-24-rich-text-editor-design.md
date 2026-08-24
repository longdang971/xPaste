# A formatting editor for Text items — design

**Goal:** The edit mode built in `2026-08-21-edit-item-design.md` can change what a snippet *says*
but not how it *looks*. This adds the second half: a toolbar for bold, italic, fonts, colours and
links, and a raw mode that shows the underlying markup for anyone who would rather type it.

## Scope

Text items only — every `.text` item, whether or not it arrived with formatting.

Link items keep their current behaviour and are edited as plain text. That was a deliberate call in
the earlier design: a Link is edited as the address it is, not as the styled anchor a browser
happened to put on the pasteboard. Nothing here changes it. Images, Files and Folders remain
uneditable for the reasons given there.

## The two modes

**Formatted** is what edit mode does today — a rich `NSTextView` — plus a toolbar above it.

**Raw** shows the same content as HTML source in a monospaced, plain text view. Typing there is
typing markup.

HTML is the raw representation in both directions, regardless of what the item actually stores.
Items are captured as RTF or HTML and always re-encoded to RTF on save, so the stored bytes are
usually RTF — but RTF source is not something a person edits by hand:

```rtf
{\rtf1\ansi\ansicpg1252\cocoartf2822
{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
\f0\fs26 Xin chào \b thế giới\b0\par}
```

against the same content as HTML:

```html
<p>Xin chào <b>thế giới</b></p>
<p><a href="https://vidu.com">vidu.com</a></p>
```

Raw mode exists to be typed in. HTML is the only one of the two that can be.

## Architecture

Three new files, plus changes to `ItemPreviewWindow.swift` and `ItemEdit.swift`.

### `Services/RichTextHTML.swift` — the conversion, both ways

Pure, no UI, fully testable.

`html(from: NSAttributedString) -> String` is **written here rather than delegated to Cocoa's HTML
writer**. Cocoa produces a class-based stylesheet:

```html
<style type="text/css">p.p1 {margin: 0; font: 13px Helvetica}span.s1 {font-weight: bold}</style>
<p class="p1">Xin chào <span class="s1">thế giới</span></p>
```

Technically correct and miserable to hand-edit — every change means chasing a class definition in
the header. Ours walks the attribute runs and emits what the user would write: `<b>`, `<i>`, `<u>`,
`<s>`, `<a href>`, and a `<span style="…">` carrying `font-family`, `font-size`, `color` and
`background-color` when a run departs from the defaults. One `<p>` per line; no `<br>`.

Two rules come from measuring the importer rather than from taste, and both matter:

- **A face is named by its PostScript name, never by a family plus `font-weight`.** CSS weights
  drift badly on the way back in — `'Helvetica Neue'` at `font-weight:500` returns as
  HelveticaNeue-**Medium**, at 600 as **Bold**. `font-family:HelveticaNeue-Light` returns as
  exactly that, weight intact, and `font-family:Menlo-BoldItalic` brings both traits with it.
- **The system font is the exception, and is written as `<b>`/`<i>` with no `font-family` at all.**
  Its family name is the private `.AppleSystemUIFont`, which is not something to put in a
  stylesheet. Left unnamed it picks up the prelude's `-apple-system` at 13px — which is precisely
  the editor's own default — so the ordinary case stays as clean as the example above.

Every `<p>` comes back from the importer with a trailing newline the source did not have, so the
parse drops exactly one. That is what makes the round trip exact: `"a\nb"` writes as
`<p>a</p><p>b</p>`, imports as `"a\nb\n"`, and lands back at `"a\nb"`.

`attributed(from: String) -> NSAttributedString?` uses Cocoa's HTML *importer*.
`RichTextRenderer.htmlDefaultFontPrelude` is prepended for the reason documented there: left to
itself the importer applies Times-Roman 12 to anything the fragment does not style. It is made
non-private for this.

The importer is **very** forgiving — `<p><b>unclosed` parses happily into bold text — so the nil
return is a genuine but rare path, not the normal response to a typo. This is a feature here: the
whole point of raw mode is hand-typed markup, and half-finished markup should render rather than
stop the user.

Both directions are capped at `RichTextRenderer.htmlByteCap` (256KB) measured on the HTML string —
the generated markup on the way out, the typed source on the way in. The importer is WebKit-backed
and main-thread only, so a half-megabyte item must be refused entry to raw mode rather than allowed
to freeze the panel. Over the cap, the toggle is disabled and its tooltip says why.

The raw view is the same `NSTextView`, monospaced, with `isRichText` off — nothing pasted into it
can smuggle formatting into what is meant to be a plain source buffer.

The empty-draft rule is checked in two places at two costs. The Save *button* dims on a blank source
buffer, a string test cheap enough to run per keystroke. `save()` itself parses once and refuses an
empty *rendered* result, so markup that renders to nothing is caught even though the button was lit.
Parsing on every keystroke to dim the button earlier would put a WebKit document build on the main
thread per character — the exact cost `RichTextRenderer`'s parse cache exists to avoid.

### `Services/RichTextCommand.swift` — applying formatting

Operates on an `NSTextStorage` and an `NSRange`, returns the `typingAttributes` the text view should
adopt. No window required, so every command is testable directly.

Commands: `bold`, `italic`, `underline`, `strikethrough`, `font(family:)`, `weight(_:)`, `size(_:)`,
`colour(_:)`, `highlight(_:)`, `link(URL?)`, `clearFormatting`.

Bold and italic go through `NSFontManager.convert(_:toHaveTrait:)` so a family without a real bold
face is not given a synthesised one behind the user's back.

**With no selection, a command changes only `typingAttributes`.** Pressing **B** and then typing
produces bold text, exactly as TextEdit behaves. Getting this wrong — making the buttons no-ops
without a selection — is the single most likely way for the toolbar to feel broken.

### `Views/RichTextToolbar.swift`

One row under the header:

```
B  I  U  S │ Helvetica ⌄ │ 13 ⌄ │ A▾ ▨▾ │ 🔗 │ ✕A │           Aa | </>
```

- **B / I / U / S** are toggles, lit according to the formatting at the caret. State refreshes from
  `textViewDidChangeSelection`.
- **Font menu** lists families and, in the same menu, weights (Light, Regular, Semibold, Bold). A
  "light" face is a weight, not a separate button. The family list comes from
  `NSFontManager.availableFontFamilies`, built once and cached statically. The system family takes
  the `NSFont.systemFont(ofSize:weight:)` path and every other family
  `NSFontManager.font(withFamily:traits:weight:size:)`, because the system font's private family
  name is not something `NSFontManager` will look up.
- **Size menu**: 9, 10, 11, 12, 13, 14, 18, 24, 36, 48, plus the current size when it is none of
  those.
- **Text colour (A▾) and highlight (▨▾)** are menus containing a swatch grid, each with a
  "Default"/"None" entry.

  **Not SwiftUI's `ColorPicker`.** It opens `NSColorPanel`, a separate window, which takes key
  status — and the panel's glass follows the key window, so xPaste's panel dims behind it. This is
  the failure recorded when the delete confirmation moved to its own window; child windows and
  overriding `isKeyWindow` were both tried there and neither helped. A menu of preset swatches
  stays inside the popover and avoids the whole class of problem.
- **✕A** returns the selection to the plain defaults.
- **Aa | </>** switches modes. In raw mode every formatting control is disabled — they have no
  meaning over a plain string — leaving only the toggle.

### Link insertion

The 🔗 button reveals a second row inside the popover: an address field, an **Apply** button and a
**Remove link** button. In the popover, not a sheet or a window — same key-window reasoning as the
colour menus.

When the caret sits inside an existing link the field is pre-filled with that address and the button
reads **Update**. With a selection, the link is applied to it; without one, the typed address is
inserted as its own linked text.

### `Services/EditSession.swift` — one source of truth

`EditBuffer` moves here out of `ItemPreviewWindow.swift` to sit beside it — the two are one idea,
and the popover file is already 493 lines before any of this lands.

It holds the current mode, the seed for the view now on screen, and a `viewGeneration` counter.
`switchTo(_:)` reads the live text view through the buffer, converts, stores the result as the new
seed, and bumps the generation so SwiftUI rebuilds the representable.

This preserves the rule `EditableRichText` was built around — seed once in `makeNSView`, never write
in `updateNSView` — rather than breaking it. That comment exists because pushing a seed back on a
SwiftUI update throws away what the user has typed and moves the caret to the start; a mode switch
is a rebuild, not an update.

**Switching back without editing restores the original object.** If the raw text is byte-identical
to what `switchTo(.raw)` produced, `switchTo(.formatted)` reinstates the exact `NSAttributedString`
it came from instead of re-parsing. Every conversion round trip costs a little fidelity, and nobody
should pay it for a mis-click.

## Saving

`save()` gains one step at the front: if the editor is in raw mode, parse the HTML first. A parse
failure shows an error beneath the toolbar and neither saves nor closes — the draft stays on screen
where it can be fixed. After that, the existing path is unchanged: `ItemEdit.rtf` then
`ClipboardStore.updateContent`.

### When a plain item becomes a formatted one

Every `.text` item now opens with the toolbar, so a plain snippet can be given formatting. What it
must not do is start storing RTF merely for having been opened.

`ItemEdit.keepsFormatting`'s comment warns about exactly this: an `NSTextView` applies a default
font to everything it is given, so "does the result carry attributes?" answers yes for every plain
snippet ever opened. The test is therefore **"does anything differ from the defaults it opened
with?"** — a run whose font is not the system 13, whose colour is not `labelColor`, or which carries
a link, an underline, a strikethrough or a background. Only then is RTF written.

A plain note that gains three more plain paragraphs stays plain. The comment on `keepsFormatting` is
updated to describe the new rule rather than the old prohibition.

## Sizing

The text popover is 420×340, too narrow for the toolbar row. While editing a `.text` item it becomes
560×460 — the width the Link preview already uses. Every other pane keeps its current size.

## Accepted trade-off: undo does not cross a mode switch

Each switch rebuilds the text view, so the new mode starts with an empty undo stack. ⌘Z will not
step back across a raw ↔ formatted boundary.

Keeping it would mean a shared `NSUndoManager` with hand-written undo registration for the
conversions themselves — more work than the rest of this feature combined, for a case that arises
only when someone switches modes mid-thought. Accepted deliberately.

## Testing

Automated:

- **`RichTextHTMLTests`** — a round trip preserves bold, italic, underline, strikethrough, text
  colour, background colour, font face, size and links, and reproduces the plain string exactly
  including its newlines; content over the byte cap is refused; half-typed markup still renders.
- **`RichTextCommandTests`** — each command against an `NSTextStorage`, including the no-selection
  case where only `typingAttributes` may change, and a family with no true bold face.
- **`ItemEditTests`** — additions for the differs-from-defaults rule: a plain item edited plainly
  saves no RTF; the same item given one bold word does.
- **`EditAndSaveIntegrationTests`** — an edit made through raw mode reaches storage with its
  formatting intact.

By hand, because they cannot be observed without a screen:

- Colour swatches read correctly in dark mode.
- The panel does not dim while a font or colour menu is open.
- Toolbar state tracks the caret when clicking through mixed formatting.
