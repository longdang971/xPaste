# Editing an item — design

**Goal:** The preview popover gains an edit mode, so a Text or Link item's content can be corrected
in place — a typo in a snippet, a stale token in a command — without recopying it from the source.

## Scope

Text and Link items only.

Images are left out: editing a picture is a picture editor — crop, rotate, annotate — and that is a
larger feature than everything here put together. File and Folder items are left out too: "editing"
one means editing a path, which is a different thing from editing content and brings its own
questions about paths that no longer exist.

## Where

Inside `PreviewPopoverContent`, the popover Space already opens. It has the three things editing
needs and nothing else does: a pane big enough to type in, a footer with room for Save and Cancel,
and — for rich items — an `NSTextView` already on screen in `RichTextPreview`, which becomes the
editor by being told it is editable.

A separate window was considered and rejected: it would need its own lifecycle, its own relationship
with the panel hiding behind it, and its own answer to what happens when the item is deleted
underneath it. The popover already answers all three.

The card's right-click menu gains "Edit…", which opens the popover straight into edit mode.

## Keeping formatting

An item that captured RTF or HTML is edited **as formatted text**. The `NSTextView` is loaded with
the parsed attributed string, and what comes back out is re-encoded as RTF. Bold, colour and
highlight survive a typo fix, which is the whole point — the content most worth correcting is
exactly the content that came from a browser or an editor and arrived styled.

An HTML item becomes an RTF item on save. That is not a loss: `ClipboardItem.captureRich` already
prefers RTF over HTML when reading the pasteboard, so RTF is the representation the app treats as
primary.

An item that carried **no** rich data stays plain. The editor is a plain text view and the save
writes only `text`. This is a rule rather than a heuristic on purpose: an `NSTextView` applies a
default font to everything it is given, so "does the edited string carry attributes?" would answer
yes for every plain item that was ever opened in an editor, and plain snippets would silently start
storing RTF.

## Re-classifying on save

Whether an item is Text or Link is decided from its content, so an edit that turns
`hello` into `https://example.com` turns a Text card into a Link card.

The rule is lifted out of `ClipboardItem.from(pasteboard:)` into `ClipboardItem.contentType(for:)`
and called from both places. Capture and editing disagreeing about what counts as a link is the kind
of difference nobody notices until a card refuses to show a link preview.

## The stale-cache problem

This is the part that quietly breaks, and it is why editing is more than a text field.

An item's content is cached in six places, every one of them keyed by the item's **id** — which does
not change when the content does:

| Cache | Holds |
| --- | --- |
| `ClipboardItemCard.cardTextCache` | the character count and the truncated preview string |
| `ClipboardItemCard.richPreviewCache` | the rasterised bitmap of the formatted card |
| `ClipboardItemCard.fileTextCache` | the opening of the file a path item points at |
| `ClipboardItemCard.pathImageCache` | the thumbnail of that file |
| `RichTextRenderer.parseCache` | the parsed `NSAttributedString`, positive and negative alike |
| the card's own `@State` | `richPreview`, `fileText`, `pathImage`, `detectedFilePath` |

Purging the first five is enough for them, and the store does it on every content change.

The `@State` is the harder half. The card's `.task` is keyed on `CardTaskKey`, which carries the
item's id and the appearance — neither of which changes on an edit — so the task does not re-run and
the state is never refreshed. And the card's view identity in the `ForEach` is `item.id`, so SwiftUI
keeps the same `@State` rather than building a fresh card.

So `ClipboardItem` gains a **revision**, bumped on every content change, and `CardTaskKey` carries
it. That makes the task re-run, which is the mechanism that already exists here — it is exactly how
a light/dark flip and a new search term force a rebuild.

`revision` is `Int?` rather than `Int` because `ClipboardItem`'s `Codable` conformance is
synthesised, and a non-optional new property fails to decode every item already on disk.
`CachedLinkMeta.isDirectImage` is optional for the same reason.

Two smaller consequences follow:

- `RichCardPreview` records the revision it was built for, and `isUsable` treats a mismatch as a
  miss — the same way it already treats the wrong appearance or the wrong search term. Without it
  the stale `@State` bitmap draws for the one frame before the task finishes.
- The card's `.task` must assign its derived state **totally**, nil included. Editing a path item
  into ordinary prose leaves no file to read, and a branch that simply does not run would leave
  yesterday's file contents on the card.

## Saving

`ClipboardStore.updateContent(id:text:richData:richType:)`:

1. refuses anything that is not Text or Link, and refuses an empty result — deleting is a separate
   gesture with its own confirmation, and a save that silently deleted the item would be a trap
2. writes the new content, re-classifies the type, bumps the revision
3. purges the id-keyed caches above
4. persists the item's JSON

Position and timestamp are left alone. The timestamp records when the content was copied, and
editing is not copying; moving the card to the front would also make a correction look like new
history.

## Escape, and the panel

Entering edit mode posts `.clipboardAlertShown` and leaving posts `.clipboardAlertHidden` — the
handshake renaming already uses, which stops `AppDelegate`'s key monitor from swallowing Escape so
it can cancel the edit instead of closing the panel.

`.panelWillHide` discards an edit in progress, exactly as it discards a half-finished rename. A panel
that reopened into a half-typed edit would be worse than losing the edit.

## Errors and edge cases

- An empty or whitespace-only result — Save is disabled, so there is nothing to report
- The item deleted from under the editor (⌫ elsewhere, history cleared, retention pruned) —
  `updateContent` finds no item and does nothing; the popover closes
- Cancel, or Escape — the item is untouched, and nothing has been written at any point before Save

## Testing

Pure and store-level, no popover:

- `ClipboardItemTests` — `contentType(for:)`: http and https are links, other schemes and plain
  prose are text, and the rule matches what `from(pasteboard:)` produces
- `ItemEditTests` — an attributed string with bold and a background colour round-trips through RTF
  with both attributes intact; an empty string yields no RTF
- `ClipboardStoreTests` — an edit changes the text, bumps the revision, re-classifies text→link and
  link→text, leaves the timestamp and the pin alone, refuses an empty result, refuses an image, and
  survives a reload from disk

The popover itself — the buttons, the editable text view, Escape — is AppKit on screen and is
checked by hand.
