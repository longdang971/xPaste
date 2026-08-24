# Colour Items Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a copied colour literal a content type of its own, and give its editor the two tools a colour actually needs — conversion between notations, and a contrast reading — in place of the rich-text toolbar it gets today.

**Architecture:** One new pure service (`ColorFormat`) renders an `NSColor` back to hex/rgb/hsl, the half `ColorParser` never had. `ClipboardContentType` gains `.color`, decided in the one place that already decides type (`ClipboardItem.contentType(for:)`), so capture and editing agree for free. A one-time migration reclassifies colours already on disk. The editor swaps its formatting toolbar for a colour row.

**Tech Stack:** Swift 5.9, AppKit + SwiftUI, XCTest, macOS 13 deployment target, XcodeGen from `project.yml`.

Design: `docs/superpowers/specs/2026-08-24-colour-items-design.md`

## Global Constraints

- **`ClipboardItem.contentType(for:)` is the only place that decides what a piece of text is.** Do not add a second rule anywhere. It has exactly two callers — `ClipboardItem.from(pasteboard:)` and `ClipboardStore.updateContent` — and both must keep getting their answer from it.
- **`ColorParser` is not to be modified.** It is the shared authority on what counts as a colour; the card, the search filter and now the type all defer to it. Adding a second opinion is the failure this design exists to prevent.
- **A `.color` item never stores RTF.** `ItemEdit.keepsFormatting` must answer false for it.
- **No new windows or panels.** `NSColorPanel` and SwiftUI's `ColorPicker` are forbidden throughout this app: each is a separate window, a separate window takes key status, and the panel's glass follows the key window, so the panel visibly dims behind it. Measured when the delete confirmation moved to a window of its own.
- **Alpha is written only when the colour is not opaque.** `#1e90ff`, not `#1e90ffff`.
- Comments explain *why*, and record the measurement or failure behind a non-obvious rule. `xPaste/Services/ColorParser.swift` and `xPaste/Services/RichTextRenderer.swift` are the calibration.
- Full suite: `xcodebuild test -scheme xPaste -destination 'platform=macOS'` — currently **575/575**, and must not regress.
- New source files need `xcodegen generate` before they are in the project.

---

## File Structure

**Create:**
- `xPaste/Services/ColorFormat.swift` — `NSColor` → hex / rgb / hsl strings. Pure.
- `xPaste/Views/ColorEditRow.swift` — the swatch, the three conversion buttons, the contrast readings.
- `xPasteTests/ColorFormatTests.swift`
- `xPasteTests/ColorItemTests.swift` — classification and migration.

**Modify:**
- `xPaste/Models/ClipboardItem.swift` — the `.color` case and the `contentType(for:)` branch.
- `xPaste/Models/ClipboardStore.swift` — the load-time migration.
- `xPaste/Services/ItemEdit.swift` — `.color` is editable, never formatted.
- `xPaste/Views/ClipboardItemCard.swift`, `xPaste/Models/SearchFilters.swift` — read the type instead of deriving it.
- `xPaste/Views/ItemPreviewWindow.swift` — the colour row replaces the toolbar for `.color`.
- Every other file the compiler names — see Task 2.

---

### Task 1: `ColorFormat` — rendering a colour back to text

**Files:**
- Create: `xPaste/Services/ColorFormat.swift`, `xPasteTests/ColorFormatTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum ColorFormat { case hex, rgb, hsl }` with `var title: String`, and `func render(_ colour: NSColor) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `xPasteTests/ColorFormatTests.swift`:

```swift
import XCTest
import AppKit
import SwiftUI
@testable import xPaste

/// Rendering a colour back to a literal — the half `ColorParser` never had; it only ever read them.
final class ColorFormatTests: XCTestCase {

    private func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Rendering

    func test_hex_renders_six_digits_when_opaque() {
        XCTAssertEqual(ColorFormat.hex.render(srgb(30/255, 144/255, 255/255)), "#1e90ff")
    }

    /// Writing `ff` on the end of every opaque colour is technically correct and would annoy anyone
    /// pasting it into CSS.
    func test_hex_gains_an_alpha_pair_only_when_not_opaque() {
        let half = ColorFormat.hex.render(srgb(30/255, 144/255, 255/255, 0.5))
        XCTAssertEqual(half.count, 9, "expected #rrggbbaa, got \(half)")
        XCTAssertTrue(half.hasPrefix("#1e90ff"))
    }

    func test_rgb_renders_whole_channels() {
        XCTAssertEqual(ColorFormat.rgb.render(srgb(30/255, 144/255, 255/255)), "rgb(30, 144, 255)")
    }

    func test_rgb_becomes_rgba_when_not_opaque() {
        XCTAssertEqual(ColorFormat.rgb.render(srgb(0, 0, 0, 0.5)), "rgba(0, 0, 0, 0.5)")
    }

    func test_hsl_renders_degrees_and_percentages() {
        // Pure red: hue 0, fully saturated, half lightness.
        XCTAssertEqual(ColorFormat.hsl.render(srgb(1, 0, 0)), "hsl(0, 100%, 50%)")
    }

    func test_hsl_becomes_hsla_when_not_opaque() {
        XCTAssertTrue(ColorFormat.hsl.render(srgb(1, 0, 0, 0.5)).hasPrefix("hsla("))
    }

    func test_grey_renders_with_no_saturation() {
        XCTAssertEqual(ColorFormat.hsl.render(srgb(0.5, 0.5, 0.5)), "hsl(0, 0%, 50%)")
    }

    /// A colour arriving in a colour space other than sRGB must not throw — reading `.redComponent`
    /// off a Generic Gray colour raises an uncatchable exception, the trap `RichTextRenderer`
    /// documents.
    func test_a_generic_grey_colour_renders_rather_than_raising() {
        XCTAssertFalse(ColorFormat.hex.render(NSColor.black).isEmpty)
    }

    // MARK: - Round trip through the parser

    /// Every rendering has to be something `ColorParser` reads back, or the buttons produce text the
    /// app itself no longer recognises as a colour.
    func test_every_rendering_parses_back_to_the_same_colour() throws {
        for original in [srgb(30/255, 144/255, 255/255), srgb(1, 0, 0), srgb(0, 0, 0),
                         srgb(1, 1, 1), srgb(0.2, 0.7, 0.35)] {
            for format in [ColorFormat.hex, .rgb, .hsl] {
                let text = format.render(original)
                let parsed = try XCTUnwrap(ColorParser.parse(text), "\(text) did not parse back")
                let back = NSColor(parsed).usingColorSpace(.sRGB)!
                XCTAssertEqual(back.redComponent, original.redComponent, accuracy: 0.01, text)
                XCTAssertEqual(back.greenComponent, original.greenComponent, accuracy: 0.01, text)
                XCTAssertEqual(back.blueComponent, original.blueComponent, accuracy: 0.01, text)
            }
        }
    }

    func test_alpha_survives_the_round_trip() throws {
        for format in [ColorFormat.hex, .rgb, .hsl] {
            let text = format.render(srgb(0.1, 0.2, 0.3, 0.5))
            let parsed = try XCTUnwrap(ColorParser.parse(text), text)
            XCTAssertEqual(NSColor(parsed).alphaComponent, 0.5, accuracy: 0.01, text)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/ColorFormatTests 2>&1 | tail -20`

Expected: compilation failure — `cannot find 'ColorFormat' in scope`.

- [ ] **Step 3: Write the implementation**

Create `xPaste/Services/ColorFormat.swift`:

```swift
import AppKit

/// Rendering a colour back to a literal.
///
/// The other half of `ColorParser`, which only ever read them. Kept apart from it so the parser
/// stays the single authority on what *counts* as a colour — this file has no opinion on that, it
/// only writes what it is handed.
enum ColorFormat: CaseIterable {
    case hex
    case rgb
    case hsl

    var title: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        }
    }

    /// The literal for `colour`, in this notation.
    ///
    /// Alpha is written only when the colour is not opaque: `#1e90ff` rather than `#1e90ffff`,
    /// because the six-digit form is what anyone pasting into CSS expects.
    func render(_ colour: NSColor) -> String {
        // Converted first because reading `.redComponent` off a colour in another space — `NSColor
        // .black` is Generic Gray — raises an uncatchable NSInvalidArgumentException. The same trap
        // `RichTextRenderer` documents.
        let c = colour.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent, a = c.alphaComponent
        let opaque = a >= 0.999

        switch self {
        case .hex:
            let base = String(format: "#%02x%02x%02x", channel(r), channel(g), channel(b))
            return opaque ? base : base + String(format: "%02x", channel(a))
        case .rgb:
            let base = "\(channel(r)), \(channel(g)), \(channel(b))"
            return opaque ? "rgb(\(base))" : "rgba(\(base), \(number(a)))"
        case .hsl:
            let (h, s, l) = hsl(r: r, g: g, b: b)
            let base = "\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
            return opaque ? "hsl(\(base))" : "hsla(\(base), \(number(a)))"
        }
    }

    private func channel(_ value: CGFloat) -> Int {
        Int((min(max(value, 0), 1) * 255).rounded())
    }

    /// Trailing zeros dropped, so an alpha of a half reads `0.5` rather than `0.500000`.
    private func number(_ value: CGFloat) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%g", rounded)
    }

    /// The inverse of `ColorParser.fromHSL`, kept here rather than there so the parser keeps its one
    /// direction.
    private func hsl(r: CGFloat, g: CGFloat, b: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let maxV = max(r, g, b), minV = min(r, g, b)
        let l = (maxV + minV) / 2
        guard maxV != minV else { return (0, 0, l) }   // grey has no hue to report
        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: CGFloat
        switch maxV {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h = (h / 6) * 360
        return (h, s, l)
    }
}
```

- [ ] **Step 4: Regenerate and run the tests**

Run: `cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild test -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/ColorFormatTests 2>&1 | tail -20`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add xPaste/Services/ColorFormat.swift xPasteTests/ColorFormatTests.swift xPaste.xcodeproj/project.pbxproj
git commit -m "Render a colour back to hex, rgb and hsl"
```

---

### Task 2: `.color` becomes a content type

**Files:**
- Modify: `xPaste/Models/ClipboardItem.swift`, `xPaste/Services/ItemEdit.swift`, and every file the compiler names
- Create: `xPasteTests/ColorItemTests.swift`

**Interfaces:**
- Consumes: `ColorParser.isColor(_:)`.
- Produces: `ClipboardContentType.color`; `contentType(for:)` answers it; `ItemEdit.keepsFormatting` answers false for it.

- [ ] **Step 1: Write the failing tests**

Create `xPasteTests/ColorItemTests.swift`:

```swift
import XCTest
import AppKit
@testable import xPaste

/// A colour literal is a content type of its own, decided in the one place that decides type.
final class ColorItemTests: XCTestCase {

    func test_the_notations_the_parser_accepts_are_classified_as_colours() {
        for literal in ["#1e90ff", "#fff", "#1e90ff80", "rgb(30, 144, 255)",
                        "rgba(30, 144, 255, 0.5)", "hsl(210, 100%, 56%)"] {
            XCTAssertEqual(ClipboardItem.contentType(for: literal), .color, literal)
        }
    }

    /// Prose that merely mentions a colour is prose. `ColorParser` decides this, and it anchors its
    /// patterns for exactly this reason — the test is here to keep the type honest about deferring.
    func test_prose_mentioning_a_colour_stays_text() {
        for text in ["the background is #1e90ff", "#1e90ff is nice", "hello", "#zzzzzz"] {
            XCTAssertEqual(ClipboardItem.contentType(for: text), .text, text)
        }
    }

    func test_a_link_is_still_a_link() {
        XCTAssertEqual(ClipboardItem.contentType(for: "https://example.com"), .url)
    }

    /// Capture and editing must not be able to disagree: both ask `contentType(for:)`.
    func test_editing_a_colour_into_prose_reclassifies_it_and_back_again() {
        XCTAssertEqual(ClipboardItem.contentType(for: "#1e90ff"), .color)
        XCTAssertEqual(ClipboardItem.contentType(for: "not a colour any more"), .text)
        XCTAssertEqual(ClipboardItem.contentType(for: "rgb(1, 2, 3)"), .color)
    }

    // MARK: - What the editor may do with one

    func test_a_colour_is_editable() {
        XCTAssertTrue(ItemEdit.canEdit(.color))
    }

    /// A seven-character hex code has no business carrying an RTF document.
    func test_a_colour_never_keeps_formatting() {
        let colour = ClipboardItem(type: .color, text: "#1e90ff")
        XCTAssertFalse(ItemEdit.keepsFormatting(colour))
        XCTAssertFalse(ItemEdit.editorSeed(for: colour, parsed: nil).formatted)
    }

    func test_a_colour_item_pastes_its_text() {
        let pb = NSPasteboard(name: .init("colour-test"))
        ClipboardItem(type: .color, text: "#1e90ff").write(to: pb)
        XCTAssertEqual(pb.string(forType: .string), "#1e90ff")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/ColorItemTests 2>&1 | tail -20`

Expected: compilation failure — `type 'ClipboardContentType' has no member 'color'`.

- [ ] **Step 3: Add the case and the branch**

In `xPaste/Models/ClipboardItem.swift`, add the case:

```swift
enum ClipboardContentType: String, Codable {
    case text, url, color, image, file, folder
}
```

and add the colour branch to `contentType(for:)`, before the URL check, keeping the existing doc comment and extending it:

```swift
    static func contentType(for text: String) -> ClipboardContentType {
        // Asked before the URL check for the reader's sake rather than for correctness — nothing
        // that parses as a colour also parses as an http URL. `ColorParser` decides; this must not
        // grow a second opinion about what a colour is.
        if ColorParser.isColor(text) { return .color }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            return .text
        }
        return .url
    }
```

- [ ] **Step 4: Let the compiler find every switch, and fix each by its rule**

Run: `xcodebuild -scheme xPaste -configuration Debug -derivedDataPath build/debug build 2>&1 | grep -E "error:" | head -40`

There are around 84 sites across 16 files. Do **not** guess at them — build, fix what it names, build again. Each falls into one of three rules:

1. **"Is this text?"** — grouped cases like `case .text, .url:` that concern *text content*: add `.color`. A colour is text, and everything that works on text (search, transforms, saving to a file, dragging out as text, plain-text paste, the character count in the preview footer) must keep working for it. This is the large majority.
2. **"What kind of card is this?"** — display decisions that name a type: `.color` gets its own arm. `ClipboardItemCard`'s title already answers "Color" by deriving; it should now answer from the type. Task 3 covers the card and the filter specifically — here, just make them compile without changing behaviour.
3. **"Is this a file or a picture?"** — anything about `fileURLs` or `imageData`: `.color` behaves exactly like `.text`, which for those is "no".

When a site's right answer is not obvious from these rules, stop and ask rather than guessing — a wrong arm here is a feature that silently stops working for colours only.

- [ ] **Step 5: Teach `ItemEdit` about it**

In `xPaste/Services/ItemEdit.swift`:

```swift
    static func canEdit(_ type: ClipboardContentType) -> Bool {
        switch type {
        case .text, .url, .color:    return true
        case .image, .file, .folder: return false
        }
    }
```

and extend `keepsFormatting`'s doc comment and body so a colour is excluded:

```swift
    /// Whether the editor offers formatting for this item.
    ///
    /// Every Text item, now that there is a toolbar — a plain snippet can be given a bold word or a
    /// link. A Link is excluded: it is edited as the address it is, not as the styled anchor a
    /// browser happened to put on the pasteboard. A Colour is excluded for the same shape of
    /// reason — bold, a font family or a highlight mean nothing to `#1e90ff`, and letting one
    /// through would make `carriesFormatting` store an RTF document for seven characters.
    ///
    /// This used to also require that the item *arrived* formatted. That guard has not been
    /// dropped, it has moved to `carriesFormatting`, which asks the sharper question: does the
    /// saved text differ from the defaults it opened with?
    static func keepsFormatting(_ item: ClipboardItem) -> Bool {
        item.type == .text
    }
```

(`keepsFormatting`'s body already answers false for anything that is not `.text`; only the comment needs to say why a colour is one of them.)

Then check `editorSeed(for:parsed:)`: its `formatted` half returns `item.type == .text`, which is already correct for `.color`. Confirm rather than change.

- [ ] **Step 6: Run the full suite**

Run: `xcodebuild test -scheme xPaste -destination 'platform=macOS' 2>&1 | grep -E "Executed [0-9]+ tests, with|TEST SUCCEEDED|TEST FAILED|warning:" | tail -6`

Expected: `** TEST SUCCEEDED **`. Existing tests that assert a colour literal is `.text` were pinning the old rule — update them, and list each one in your report.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Make a colour literal a content type of its own"
```

---

### Task 3: Migration, and the card stops deriving

**Files:**
- Modify: `xPaste/Models/ClipboardStore.swift`, `xPaste/Views/ClipboardItemCard.swift`, `xPaste/Models/SearchFilters.swift`
- Modify: `xPasteTests/ColorItemTests.swift`

**Interfaces:**
- Consumes: `ClipboardItem.contentType(for:)`.
- Produces: colours already on disk load as `.color`; `SearchFilters` and the card read `item.type`.

- [ ] **Step 1: Write the failing tests**

Append to `xPasteTests/ColorItemTests.swift`. Follow the store setup the existing `ClipboardStoreTests` uses — an instance on a temporary directory, never `ClipboardStore.shared`, which is the real history:

```swift
    // MARK: - Migration

    /// Every colour ever copied is on disk as `"type": "text"`. Without this there would be two
    /// classes of colour item: old ones the editor still treats as prose, new ones it does not.
    func test_a_colour_stored_as_text_loads_as_a_colour() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColorMigration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seed = ClipboardStore(maxItems: 50, storageDir: dir)
        seed.add(ClipboardItem(type: .text, text: "#1e90ff"))
        seed.add(ClipboardItem(type: .text, text: "just prose"))
        seed.flushPendingWrites()

        let reopened = ClipboardStore(maxItems: 50, storageDir: dir)
        let colour = try XCTUnwrap(reopened.items.first { $0.text == "#1e90ff" })
        let prose = try XCTUnwrap(reopened.items.first { $0.text == "just prose" })
        XCTAssertEqual(colour.type, .color, "the stored colour was not reclassified")
        XCTAssertEqual(prose.type, .text)
    }
```

If `flushPendingWrites` or the initialiser signature differs, follow whatever `xPasteTests/ClipboardStoreTests.swift` already does — it is the authority on this store's API.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/ColorItemTests 2>&1 | tail -20`

Expected: FAIL — the reloaded item is still `.text`.

- [ ] **Step 3: Migrate on load**

In `xPaste/Models/ClipboardStore.swift`, in the load path where each item is decoded (around the `decoder.decode(ClipboardItem.self…)` guard), reclassify a decoded `.text` item whose text is a colour. Put it next to the existing legacy migration, and comment it:

```swift
                // Colour became a type of its own after these items were written, so every colour
                // ever copied is on disk as `.text`. Reclassifying on load is what stops there
                // being two classes of colour item — old ones the editor treats as prose, new ones
                // it does not. Cheap: `ColorParser`'s length gate rejects anything over 64 bytes
                // before it looks at the string.
                var item = item
                if item.type == .text, let text = item.text,
                   ClipboardItem.contentType(for: text) == .color {
                    item.type = .color
                }
```

- [ ] **Step 4: Stop deriving in the card and the filter**

In `xPaste/Models/SearchFilters.swift`, replace the two derived arms:

```swift
        case .text:   return item.type == .text
        case .color:  return item.type == .color
```

In `xPaste/Views/ClipboardItemCard.swift`, `detectedColor` keeps parsing — the card needs the actual `Color` to paint — but the *question* "is this a colour?" now comes from the type. Gate the parse on it, and say why:

```swift
    /// The colour this item represents. Gated on the type rather than asking `ColorParser` outright:
    /// the type already answered that question at capture, and this runs on every body pass — which
    /// is the reason `ColorParser` carries a length gate at all.
    private var detectedColor: Color? {
        guard item.type == .color, let text = item.text else { return nil }
        return ColorParser.parse(text)
    }
```

Then check every other `detectedColor == nil` / `!= nil` site in that file still reads correctly, and the title arm that returns `"Color"`.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild test -scheme xPaste -destination 'platform=macOS' 2>&1 | grep -E "Executed [0-9]+ tests, with|TEST SUCCEEDED|TEST FAILED|warning:" | tail -6`

Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "Reclassify stored colours, and read the type instead of re-deriving it"
```

---

### Task 4: The colour row in the editor

**Files:**
- Create: `xPaste/Views/ColorEditRow.swift`
- Modify: `xPaste/Views/ItemPreviewWindow.swift`

**Interfaces:**
- Consumes: `ColorFormat`, `ColorParser.parse(_:)`, `RichTextRenderer.contrastRatio(_:_:)`, `EditSession` (`buffer`, `generation`).
- Produces: `struct ColorEditRow: View`.

- [ ] **Step 1: Write the row**

Create `xPaste/Views/ColorEditRow.swift`:

```swift
import SwiftUI
import AppKit

/// What sits above the field while a colour is being edited, in place of the formatting toolbar.
///
/// Bold, a font family and a highlight mean nothing to `#1e90ff`; conversion between notations and
/// a contrast reading are what a colour actually needs. Everything here stays inside the popover —
/// `NSColorPanel` and SwiftUI's `ColorPicker` are both separate windows, and a separate window takes
/// key status, which the panel's glass follows and visibly dims behind. Measured when the delete
/// confirmation moved to a window of its own.
struct ColorEditRow: View {
    /// The text currently in the editor. The row is rebuilt as it changes.
    let text: String
    /// Applies a rewritten literal to the editor.
    let onRewrite: (String) -> Void

    private var colour: NSColor? {
        ColorParser.parse(text).map { NSColor($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            swatch
            HStack(spacing: 4) {
                ForEach(ColorFormat.allCases, id: \.title) { format in
                    Button(format.title) {
                        if let colour { onRewrite(format.render(colour)) }
                    }
                    .controlSize(.small)
                    .disabled(colour == nil)
                }
            }
            Spacer()
            if let colour { contrast(for: colour) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(colour.map { Color(nsColor: $0) } ?? Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    // Every palette colour is a solid fill and white is one of them, so without a
                    // hairline the white swatch would be invisible against a light popover.
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            .frame(width: 44, height: 22)
    }

    /// The ratio alone says nothing without the threshold, so each reading carries its WCAG verdict
    /// for normal body text — that is the question someone picking a UI colour is actually asking.
    private func contrast(for colour: NSColor) -> some View {
        HStack(spacing: 8) {
            reading(colour, against: .white, label: "on white")
            reading(colour, against: .black, label: "on black")
        }
    }

    private func reading(_ colour: NSColor, against background: NSColor, label: String) -> some View {
        let ratio = RichTextRenderer.contrastRatio(colour, background)
        return Text("\(label) \(String(format: "%.1f", ratio)):1 \(verdict(ratio))")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    private func verdict(_ ratio: CGFloat) -> String {
        if ratio >= 7 { return "AAA" }
        if ratio >= 4.5 { return "AA" }
        return "✕"
    }
}
```

- [ ] **Step 2: Put it in the popover**

In `xPaste/Views/ItemPreviewWindow.swift`, add a computed property beside `editingText`:

```swift
    private var editingColour: Bool { isEditing && item.type == .color }
```

and extend `content`'s editing branch so a colour gets the row instead of the toolbar. The editor itself is unchanged — a colour edits as plain text, which `ItemEdit.editorSeed` already arranges:

```swift
        if isEditing {
            if editingText {
                VStack(spacing: 0) {
                    RichTextToolbar(session: session)
                    Divider()
                    editor
                }
            } else if editingColour {
                VStack(spacing: 0) {
                    ColorEditRow(text: colourDraft) { rewritten in
                        session.replaceAll(with: rewritten)
                    }
                    Divider()
                    editor
                }
            } else {
                editor
            }
        } else {
```

`colourDraft` is `@State` on the popover, seeded when editing begins and updated from the editor's existing `onChange` closure so the row follows what is typed:

```swift
    /// What the colour row is reading. Kept as its own `@State` rather than asking the buffer in
    /// `body`, for the same reason `draftIsEmpty` is: `body` runs far more often than the text
    /// changes.
    @State private var colourDraft = ""
```

Set it in `setEditing(true)` alongside `draftIsEmpty`, and in the editor's `onChange` alongside it.

- [ ] **Step 3: Add `replaceAll(with:)` to the session**

The row rewrites the whole field. In `xPaste/Services/EditSession.swift`:

```swift
    /// Replaces the whole document, through the text view's own change machinery so the rewrite
    /// lands on its undo stack — a conversion the user did not mean must be one ⌘Z away.
    func replaceAll(with string: String) {
        guard let view = buffer.textView else { return }
        let whole = NSRange(location: 0, length: (view.string as NSString).length)
        guard view.shouldChangeText(in: whole, replacementString: string) else { return }
        view.replaceCharacters(in: whole, with: string)
        view.didChangeText()
    }
```

- [ ] **Step 4: Build and run the full suite**

Run: `cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild test -scheme xPaste -destination 'platform=macOS' 2>&1 | grep -E "Executed [0-9]+ tests, with|TEST SUCCEEDED|TEST FAILED|warning:" | tail -6`

Then: `xcodebuild -scheme xPaste -configuration Debug -derivedDataPath build/debug build 2>&1 | tail -3`

Expected: `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`. **Do not launch the app** — the by-hand pass is done separately.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Give a colour item conversion buttons and a contrast reading"
```

---

### Task 5: The by-hand pass

- [ ] Copy `#1e90ff`, `rgb(30, 144, 255)` and `hsl(210, 100%, 56%)`; each is titled "Color" and paints a swatch.
- [ ] Open one for editing: the formatting toolbar is gone, the colour row is there, the swatch matches the card.
- [ ] Each of HEX / RGB / HSL rewrites the field, and ⌘Z puts it back.
- [ ] The contrast verdicts are legible against the popover in both light and dark appearance.
- [ ] Edit the code into prose: the swatch and readings disappear, the buttons grey out, and after saving the card is an ordinary Text card.
- [ ] Edit prose into a colour code: after saving it becomes a Color card.
- [ ] A colour that was in the history *before* this change loads as a Color card.
- [ ] The Color chip in the search bar still finds exactly the colour cards.
