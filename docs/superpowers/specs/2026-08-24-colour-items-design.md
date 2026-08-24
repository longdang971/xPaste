# Colour items — design

**Goal:** A copied colour literal becomes a content type in its own right, so the editor can offer
what a colour actually needs — conversion between notations and a contrast reading — instead of the
bold/italic/font toolbar it gets today.

## Why now

`#1e90ff` is already recognised: the card paints a swatch, the panel titles it "Color", and the
search bar has a Color chip. But that recognition is *derived* at draw time, and only by the card
and the filter. Nothing else knows. So the editor opens a colour on the full rich-text toolbar —
bold, italic, font family, highlight, link — all meaningless for a seven-character hex code. Worse,
using any of them flips `ItemEdit.carriesFormatting` to true and the item starts storing an RTF
document for a colour literal.

## Scope

A new `ClipboardContentType.color`, its classification, its migration, and its editor. Conversion
between notations and a contrast reading are the two tools the editor gains.

Out of scope, deliberately: generating tints and shades, naming colours ("Dodger Blue"), and picking
a colour off the screen. Those are a design tool's job, not a clipboard manager's. A colour picker
for nudging the value is also out — see the note at the end.

## Classification

`ClipboardItem.contentType(for:)` gains one branch: text that `ColorParser` parses is `.color`.

That function is the single place the app decides what a piece of text is, and it already has
exactly two callers — capture (`ClipboardItem.from(pasteboard:)`) and editing
(`ClipboardStore.updateContent`). Putting the branch there is what makes capture and editing agree
for free: paste `#1e90ff` and it is a colour; edit a colour into prose and it stops being one, with
no second rule to keep in sync.

Colour is checked before the URL branch. Nothing that parses as a colour also parses as an `http`
URL, so the order is for the reader rather than for correctness.

`ColorParser` stays exactly as it is. It is already the shared authority — its own doc comment says
it was lifted out of the card so the filter and the card could not disagree — and this change makes
the type system the third party to that agreement rather than adding a fourth opinion.

## Migration

Items already on disk carry `"type": "text"`, including every colour ever copied. Left alone there
would be two classes of colour item: old ones the editor still treats as prose, new ones it does
not.

So the store reclassifies once on load: any `.text` item whose text parses as a colour becomes
`.color`. This is cheap — the parser's length gate rejects anything over 64 bytes before it looks at
the string — and it runs where the existing legacy migration already runs.

**Accepted risk:** once an item is written as `"type": "color"`, a build without this change cannot
decode it. The load path decodes item by item (`ClipboardStore`, the `try?` around each
`decoder.decode`), so such a build skips those items rather than losing the history — but the colour
items are gone from its view. This is a personal app whose owner controls its releases, and the
alternative (never widening the stored vocabulary) is worse. Noted rather than mitigated.

## What stops deriving

The card, the panel title and the search filter currently ask `ColorParser` on every pass. They
switch to reading `item.type`. `ColorParser.parse` is still called to get the actual `Color` for
painting, but the *question* "is this a colour?" is answered by the type from now on.

This removes a parse from the card's body pass, which is the reason `ColorParser` carries a length
gate at all.

## The editor for a colour item

A colour item is editable, like any text. What changes is what surrounds the field.

**Gone:** the formatting toolbar, the raw-HTML toggle, and any possibility of storing RTF.
`ItemEdit.keepsFormatting` answers false for `.color`, so the editor is the plain one, and
`carriesFormatting` never gets a chance to promote a colour into a rich item.

**In its place,** one row:

- a swatch, large enough to judge the colour rather than merely locate it
- **HEX**, **RGB**, **HSL** — each rewrites the field in place, in that notation
- two contrast readings, against white and against black

The field itself stays an ordinary editable text field. Typing the code by hand is still the fastest
way to change one digit, and nothing here should get in the way of that.

### Conversion

A new `ColorFormat` renders an `NSColor` back to each notation, which is the half `ColorParser` has
never had — it only ever read them.

Alpha is preserved and only written when it is not opaque: `#1e90ff` stays six digits, while a
colour with alpha becomes `#1e90ff80`, `rgba(...)`, `hsla(...)`. Writing `ff` on the end of every
hex code would be technically correct and would annoy anyone who copied it to paste into CSS.

**A conversion is not a round trip.** `ColorParser` yields a `Color`, which is 8-bit RGB, so
`hsl(210, 100%, 56%)` → HEX → HSL will not come back with the same numbers. That is inherent to
going through a colour value rather than editing the text, and it is the reason these buttons rewrite
the field — where the user can see the result and undo it — rather than silently rewriting the item.

### Contrast

`RichTextRenderer.contrastRatio(_:_:)` already computes the WCAG ratio and is already used for the
card's legibility guard. The row reuses it against white and black.

The ratio alone is not the useful part — "4.7:1" means nothing without the threshold. Each reading
carries its WCAG verdict for normal body text (AA at 4.5:1, AAA at 7:1), which is the question
someone picking a UI colour is actually asking.

### When the text stops being a colour

Editing `#1e90ff` into `hello` is allowed. The swatch and the contrast readings disappear, and the
three conversion buttons disable, because there is nothing to convert. On save the item reclassifies
to `.text` through `contentType(for:)` — the same rule that made it a colour in the first place.

## Testing

Automated:

- **`ColorFormatTests`** — every notation renders as expected; alpha appears only when not opaque; a
  parse → render → parse round trip lands on the same colour within 8-bit tolerance.
- **`ClipboardItemTests`** — `contentType(for:)` answers `.color` for the notations `ColorParser`
  accepts and `.text` for prose that merely mentions one; a colour edited into prose reclassifies,
  and prose edited into a colour does too.
- **`ClipboardStoreTests`** — the migration reclassifies an existing `.text` colour on load and
  leaves everything else alone.
- **`ItemEditTests`** — `keepsFormatting` is false for `.color`, so a colour can never store RTF.

By hand, because they cannot be observed without a screen:

- the swatch reads as the colour at a glance, in both appearances
- the contrast verdicts are legible against the popover's own background
- the row does not crowd the popover at its narrowest

## Deferred: a picker

Nudging the colour visually — a gradient area or sliders — is the obvious next thing and is
deliberately not here. `NSColorPanel` and SwiftUI's `ColorPicker` are both forbidden throughout this
app: each is a separate window, a separate window takes key status, and the panel's glass follows the
key window, so the panel visibly dims behind it. A picker therefore has to be built by hand inside
the popover, which is more work than everything above put together. Worth doing only if converting
and reading contrast turn out not to be enough.
