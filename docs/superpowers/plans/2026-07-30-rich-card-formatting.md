# Rich Card Formatting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Draw a clipboard card's real formatting — background, text colour, font, size — instead of flattening it to plain text, matching what the item does when pasted.

**Architecture:** A new `RichTextRenderer` service parses the already-captured `richData` (RTF/HTML), decides the card's fill from the run background covering the most characters, and rasterises the styled text into an `NSImage` once per item. `ClipboardItemCard` caches that image in a count-bounded `NSCache` and draws it, so TextKit never runs during a body pass. The preview popover uses the same parse through a read-only `NSTextView`, where selection matters more than speed.

**Tech Stack:** Swift 5.9, AppKit (`NSAttributedString`, `NSTextView`), SwiftUI, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-07-30-rich-card-formatting-design.md`

## Global Constraints

- Deployment target macOS 13.0; `SWIFT_VERSION` 5.9. No new dependencies.
- Every new `.swift` file requires `cd /Users/pikalong/xPaste && xcodegen generate` before it compiles — `project.yml` globs directories, it does not list files.
- Always `cd /Users/pikalong/xPaste` in the **same** shell command as `xcodebuild`; the shell cwd resets between calls and the build silently targets the wrong directory.
- SourceKit reports bogus "Cannot find X in scope" errors across this project. Trust `xcodebuild`, not editor diagnostics.
- Do not change capture or paste: `ClipboardItem.captureRich(from:)` and `ClipboardItem.write(to:)` stay byte-for-byte identical, and `ClipboardItemTests` must keep passing untouched.
- Size caps, exact values: RTF `4_000_000` bytes, HTML `262_144` bytes, card text `1500` characters, contrast floor `1.5`.
- The panel's open path is 16–25ms and must stay in that band (Task 5 verifies).
- Only `.text` and `.url` items can render rich. `.image`, `.file`, `.folder` are untouched.

---

## File Structure

| File | Responsibility |
| --- | --- |
| Create: `xPaste/Services/RichTextRenderer.swift` | Parsing, fill selection, legibility, rasterisation. All pure or main-actor static functions; no view code. |
| Create: `xPasteTests/RichTextRendererTests.swift` | Fixtures replicating the three observed Paste cards, plus caps and guard coverage. |
| Modify: `xPaste/App/AppDelegate.swift:779-793` | Add `PanelLayout.cardFooterHeight` so the card and the renderer agree on the content rect. |
| Modify: `xPaste/Views/ClipboardItemCard.swift` | Cache + `.task` population, rich branch in `contentPreview`, fill on `defaultFooter`. |
| Modify: `xPaste/Views/ItemPreviewWindow.swift` | `RichTextView` wrapper and the rich branch in `textContent`. |

---

## Task 1: Parsing and fill selection

**Files:**
- Create: `xPaste/Services/RichTextRenderer.swift`
- Test: `xPasteTests/RichTextRendererTests.swift`

**Interfaces:**
- Consumes: `ClipboardItem` (`type`, `text`, `richData`, `richType`) from `xPaste/Models/ClipboardItem.swift`.
- Produces:
  - `final class ParsedRich: @unchecked Sendable` with `let text: NSAttributedString`, `let documentBackground: NSColor?`
  - `RichTextRenderer.rtfByteCap: Int`, `.htmlByteCap: Int`, `.cardCharLimit: Int`, `.contrastFloor: CGFloat`
  - `RichTextRenderer.parse(_ item: ClipboardItem) -> ParsedRich?`
  - `RichTextRenderer.dominantBackground(of text: NSAttributedString) -> NSColor?`
  - `RichTextRenderer.dominantForeground(of text: NSAttributedString) -> NSColor`
  - `RichTextRenderer.resolveFill(runBackground: NSColor?, documentBackground: NSColor?) -> NSColor?`
  - `RichTextRenderer.contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat`
  - `RichTextRenderer.isLegible(_ text: NSAttributedString, on fill: NSColor) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `xPasteTests/RichTextRendererTests.swift`:

```swift
import XCTest
import AppKit
@testable import xPaste

final class RichTextRendererTests: XCTestCase {

    // MARK: - Fixtures
    //
    // These three replicate exactly the items that were copied and photographed in Paste's own
    // panel, which is where the fill rule in the spec comes from. Keep the character counts:
    // the majority arithmetic is the point of the second and third fixtures.

    /// A terminal transcript: every character carries a black run background. 78 chars.
    private func terminalFixture() -> ClipboardItem {
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "$ git status\n", attributes: [
            .font: mono, .foregroundColor: NSColor.white, .backgroundColor: NSColor.black]))
        s.append(NSAttributedString(string: "On branch main\n", attributes: [
            .font: mono, .foregroundColor: NSColor.systemGreen, .backgroundColor: NSColor.black]))
        s.append(NSAttributedString(string: "nothing to commit, working tree clean\n", attributes: [
            .font: mono, .foregroundColor: NSColor.white, .backgroundColor: NSColor.black]))
        s.append(NSAttributedString(string: "$ echo done\n", attributes: [
            .font: mono, .foregroundColor: NSColor.systemYellow, .backgroundColor: NSColor.black]))
        return rtfItem(s)
    }

    /// A TextEdit document: 49 chars black, 21 yellow, 14 with no background at all (84 total).
    /// Black is a majority of the string but not unanimous, and the unbacked run is the large
    /// heading — the case that proves the rule is "most characters", not "any" or "all".
    private func textEditFixture() -> ClipboardItem {
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "REAL APP COPY\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.systemRed]))
        s.append(NSAttributedString(string: "white on black background\n", attributes: [
            .font: mono, .foregroundColor: NSColor.white, .backgroundColor: NSColor.black]))
        s.append(NSAttributedString(string: "second black line here\n", attributes: [
            .font: mono, .foregroundColor: NSColor.white, .backgroundColor: NSColor.black]))
        s.append(NSAttributedString(string: "yellow highlight run\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.systemYellow]))
        return rtfItem(s)
    }

    /// Mixed styles: 55 chars with no background, 24 yellow (79 total). No background wins.
    private func mixedFixture() -> ClipboardItem {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Big Bold Heading\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.systemRed]))
        s.append(NSAttributedString(string: "italic small line\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemBlue]))
        s.append(NSAttributedString(string: "highlighted yellow text\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black,
            .backgroundColor: NSColor.systemYellow]))
        s.append(NSAttributedString(string: "underlined link-ish\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.systemPurple,
            .underlineStyle: NSUnderlineStyle.single.rawValue]))
        return rtfItem(s)
    }

    private func rtfItem(_ s: NSAttributedString) -> ClipboardItem {
        let data = s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])!
        return ClipboardItem(type: .text, text: s.string, richData: data,
                             richType: NSPasteboard.PasteboardType.rtf.rawValue)
    }

    /// RTF colour writing round-trips through a colour table, so components can drift a little.
    private func assertSimilar(_ actual: NSColor?, _ expected: NSColor,
                               tolerance: CGFloat = 0.08,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let a = actual?.usingColorSpace(.sRGB),
              let e = expected.usingColorSpace(.sRGB) else {
            return XCTFail("expected a colour close to \(expected), got \(String(describing: actual))",
                           file: file, line: line)
        }
        XCTAssertEqual(a.redComponent, e.redComponent, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(a.blueComponent, e.blueComponent, accuracy: tolerance, file: file, line: line)
    }

    // MARK: - Character counts
    //
    // The fill rule is arithmetic over these numbers, so a fixture edit that changes them would
    // silently change what the other tests prove. Pin them.

    func test_fixture_character_counts_are_what_the_rule_assumes() {
        XCTAssertEqual(terminalFixture().text?.count, 78)
        XCTAssertEqual(textEditFixture().text?.count, 84)
        XCTAssertEqual(mixedFixture().text?.count, 79)
    }

    // MARK: - Parsing

    func test_parses_rtf_into_a_styled_string() {
        let parsed = RichTextRenderer.parse(terminalFixture())
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.text.string, terminalFixture().text)
    }

    func test_item_without_rich_data_does_not_parse() {
        let plain = ClipboardItem(type: .text, text: "just text")
        XCTAssertNil(RichTextRenderer.parse(plain))
    }

    func test_unrecognised_rich_type_does_not_parse() {
        let odd = ClipboardItem(type: .text, text: "x", richData: Data([0x41]),
                                richType: "public.utf8-plain-text")
        XCTAssertNil(RichTextRenderer.parse(odd))
    }

    func test_image_item_never_parses_even_with_rich_data() {
        let s = NSAttributedString(string: "x", attributes: [.backgroundColor: NSColor.black])
        let data = s.rtf(from: NSRange(location: 0, length: 1), documentAttributes: [:])!
        let img = ClipboardItem(type: .image, imageData: Data([0x00]),
                                richData: data,
                                richType: NSPasteboard.PasteboardType.rtf.rawValue)
        XCTAssertNil(RichTextRenderer.parse(img))
    }

    func test_oversize_rtf_is_skipped() {
        let big = ClipboardItem(type: .text, text: "x",
                                richData: Data(count: RichTextRenderer.rtfByteCap + 1),
                                richType: NSPasteboard.PasteboardType.rtf.rawValue)
        XCTAssertNil(RichTextRenderer.parse(big))
    }

    func test_oversize_html_is_skipped() {
        let big = ClipboardItem(type: .text, text: "x",
                                richData: Data(count: RichTextRenderer.htmlByteCap + 1),
                                richType: NSPasteboard.PasteboardType.html.rawValue)
        XCTAssertNil(RichTextRenderer.parse(big))
    }

    func test_parses_html_and_finds_a_run_background() {
        let html = "<span style=\"background-color:#000000;color:#ffffff\">dark run</span>"
        let item = ClipboardItem(type: .text, text: "dark run",
                                 richData: Data(html.utf8),
                                 richType: NSPasteboard.PasteboardType.html.rawValue)
        guard let parsed = RichTextRenderer.parse(item) else {
            return XCTFail("HTML did not parse")
        }
        assertSimilar(RichTextRenderer.dominantBackground(of: parsed.text), .black)
    }

    // MARK: - The fill rule

    func test_all_black_runs_give_a_black_fill() {
        let parsed = RichTextRenderer.parse(terminalFixture())!
        assertSimilar(RichTextRenderer.dominantBackground(of: parsed.text), .black)
    }

    func test_majority_background_wins_over_minority_and_unbacked_runs() {
        let parsed = RichTextRenderer.parse(textEditFixture())!
        assertSimilar(RichTextRenderer.dominantBackground(of: parsed.text), .black)
    }

    func test_unbacked_majority_keeps_the_default_fill() {
        let parsed = RichTextRenderer.parse(mixedFixture())!
        XCTAssertNil(RichTextRenderer.dominantBackground(of: parsed.text))
    }

    func test_document_background_is_only_a_fallback() {
        XCTAssertEqual(
            RichTextRenderer.resolveFill(runBackground: .red, documentBackground: .blue), .red)
        XCTAssertEqual(
            RichTextRenderer.resolveFill(runBackground: nil, documentBackground: .blue), .blue)
        XCTAssertNil(
            RichTextRenderer.resolveFill(runBackground: nil, documentBackground: nil))
    }

    func test_fully_transparent_background_counts_as_no_background() {
        let s = NSAttributedString(string: "clear run",
                                   attributes: [.backgroundColor: NSColor.clear])
        XCTAssertNil(RichTextRenderer.dominantBackground(of: s))
    }

    // MARK: - Legibility guard

    func test_contrast_ratio_endpoints() {
        XCTAssertEqual(RichTextRenderer.contrastRatio(.white, .black), 21, accuracy: 0.1)
        XCTAssertEqual(RichTextRenderer.contrastRatio(.black, .black), 1, accuracy: 0.01)
    }

    func test_white_text_with_no_background_is_illegible_on_the_default_fill() {
        let s = NSAttributedString(string: "invisible",
                                  attributes: [.foregroundColor: NSColor.white])
        XCTAssertFalse(RichTextRenderer.isLegible(s, on: .white))
    }

    func test_the_unbacked_heading_does_not_make_a_dark_card_illegible() {
        // The TextEdit fixture's red heading carries no background; the string as a whole is
        // still legible on the black fill its other runs won.
        let parsed = RichTextRenderer.parse(textEditFixture())!
        XCTAssertTrue(RichTextRenderer.isLegible(parsed.text, on: .black))
    }

    func test_dominant_foreground_defaults_to_black_when_unset() {
        let s = NSAttributedString(string: "no colour attribute")
        assertSimilar(RichTextRenderer.dominantForeground(of: s), .black)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/RichTextRendererTests 2>&1 | tail -30
```

Expected: compile failure, `cannot find 'RichTextRenderer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `xPaste/Services/RichTextRenderer.swift`:

```swift
import AppKit

/// A parsed `richData`.
///
/// A class rather than a tuple so it can cross a `Task.detached` boundary: `NSAttributedString`
/// is not `Sendable`, and RTF parsing is deliberately done off the main thread.
final class ParsedRich: @unchecked Sendable {
    let text: NSAttributedString
    /// The document-level background (an RTF `\viewbkcol`, an HTML `bgcolor`), if the source
    /// supplied one. Only a fallback — see `resolveFill`.
    let documentBackground: NSColor?

    init(text: NSAttributedString, documentBackground: NSColor?) {
        self.text = text
        self.documentBackground = documentBackground
    }
}

/// Turns a clipboard item's captured RTF/HTML into something drawable.
///
/// The rules here were read off Paste's own panel: three items were copied, photographed, and the
/// arithmetic reverse-engineered. The one that matters is `dominantBackground` — Paste fills a
/// whole card from the *run* backgrounds of the text, not from any document attribute, which is
/// why a terminal transcript fills a card black even though its RTF sets no document background.
enum RichTextRenderer {
    /// RTF parsing is off the main thread, so this cap only bounds memory and work, not latency.
    static let rtfByteCap = 4_000_000
    /// Far lower, because `NSAttributedString(html:)` is a WebKit importer that must run on the
    /// main thread — its cost lands directly on the panel.
    static let htmlByteCap = 262_144
    /// Enough to overfill the card several times at any plausible font size.
    static let cardCharLimit = 1500
    /// Below this contrast ratio the text would be near-invisible, so we draw plain text instead.
    static let contrastFloor: CGFloat = 1.5

    // MARK: - Parsing

    static func parse(_ item: ClipboardItem) -> ParsedRich? {
        guard item.type == .text || item.type == .url,
              let data = item.richData, !data.isEmpty,
              let rawType = item.richType
        else { return nil }

        var docAttrs: NSDictionary?
        let parsed: NSAttributedString?
        switch rawType {
        case NSPasteboard.PasteboardType.rtf.rawValue:
            guard data.count <= rtfByteCap else { return nil }
            parsed = NSAttributedString(rtf: data, documentAttributes: &docAttrs)
        case NSPasteboard.PasteboardType.html.rawValue:
            guard data.count <= htmlByteCap else { return nil }
            parsed = NSAttributedString(html: data, documentAttributes: &docAttrs)
        default:
            return nil
        }

        guard let parsed, parsed.length > 0 else { return nil }
        let background = (docAttrs as? [NSAttributedString.DocumentAttributeKey: Any])?[.backgroundColor] as? NSColor
        return ParsedRich(text: parsed, documentBackground: background)
    }

    // MARK: - Choosing the fill

    /// The run background covering the most characters, or nil when "no background" covers the
    /// most. Measured against Paste: 49 black of 84 characters wins the card even though 21 are
    /// yellow and 14 carry no background at all.
    static func dominantBackground(of text: NSAttributedString) -> NSColor? {
        var tally: [String: (colour: NSColor, characters: Int)] = [:]
        var unbacked = 0

        text.enumerateAttribute(.backgroundColor,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            guard let colour = (value as? NSColor)?.usingColorSpace(.deviceRGB),
                  colour.alphaComponent > 0.01 else {
                unbacked += range.length
                return
            }
            let key = colourKey(colour)
            tally[key] = (colour, (tally[key]?.characters ?? 0) + range.length)
        }

        guard let winner = tally.values.max(by: { $0.characters < $1.characters }),
              winner.characters > unbacked
        else { return nil }
        return winner.colour
    }

    /// Run backgrounds win; a document background is only consulted when no run has one.
    static func resolveFill(runBackground: NSColor?, documentBackground: NSColor?) -> NSColor? {
        runBackground ?? documentBackground
    }

    /// Two runs whose colours differ only by colour-space round-tripping must tally as one.
    private static func colourKey(_ colour: NSColor) -> String {
        String(format: "%.3f-%.3f-%.3f-%.3f",
               colour.redComponent, colour.greenComponent,
               colour.blueComponent, colour.alphaComponent)
    }

    // MARK: - Legibility

    /// The foreground colour covering the most characters. Text with no colour attribute draws
    /// black, so that is the default.
    static func dominantForeground(of text: NSAttributedString) -> NSColor {
        var tally: [String: (colour: NSColor, characters: Int)] = [:]
        text.enumerateAttribute(.foregroundColor,
                                in: NSRange(location: 0, length: text.length),
                                options: []) { value, range, _ in
            // The fallback has to go through deviceRGB as well. `NSColor.black` lives in Generic
            // Gray, which cannot answer `.redComponent` — `colourKey` would raise
            // NSInvalidArgumentException on any run with no foreground colour attribute.
            let colour = (value as? NSColor)?.usingColorSpace(.deviceRGB)
                ?? NSColor.black.usingColorSpace(.deviceRGB)!
            let key = colourKey(colour)
            tally[key] = (colour, (tally[key]?.characters ?? 0) + range.length)
        }
        return tally.values.max(by: { $0.characters < $1.characters })?.colour ?? .black
    }

    /// WCAG relative-luminance contrast ratio, 1:1 to 21:1.
    static func contrastRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private static func relativeLuminance(_ colour: NSColor) -> CGFloat {
        guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent)
             + 0.7152 * linear(c.greenComponent)
             + 0.0722 * linear(c.blueComponent)
    }

    /// Guards against a blank card: a source that hands over light text carrying no background
    /// anywhere would otherwise rasterise to nothing at all.
    static func isLegible(_ text: NSAttributedString, on fill: NSColor) -> Bool {
        contrastRatio(dominantForeground(of: text), fill) >= contrastFloor
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/pikalong/xPaste && xcodegen generate && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/RichTextRendererTests 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, 17 tests run.

If `test_parses_html_and_finds_a_run_background` fails, do not weaken it — HTML is a real capture path (`captureRich` falls back to it) and a broken HTML branch would silently disable rich rendering for every HTML-only source.

- [ ] **Step 5: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/Services/RichTextRenderer.swift xPasteTests/RichTextRendererTests.swift xPaste.xcodeproj && git commit -m "Read a clipboard item's real formatting out of its captured RTF

The fill rule is Paste's, reverse-engineered from three photographed cards:
the run background covering the most characters wins the whole card.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Rasterising a card preview

**Files:**
- Modify: `xPaste/App/AppDelegate.swift:779-793` (add `cardFooterHeight`)
- Modify: `xPaste/Services/RichTextRenderer.swift` (add the card entry points)
- Test: `xPasteTests/RichTextRendererTests.swift` (append)

**Interfaces:**
- Consumes: everything Task 1 produced.
- Produces:
  - `PanelLayout.cardFooterHeight: CGFloat` (value `30`)
  - `final class RichCardPreview` with `let image: NSImage?`, `let fill: NSColor?`, `static let plain: RichCardPreview`
  - `RichTextRenderer.cardPreviewSize: CGSize`
  - `RichTextRenderer.cardPadding: CGFloat` (value `12`)
  - `@MainActor RichTextRenderer.cardPreview(for item: ClipboardItem, size: CGSize, defaultFill: NSColor = .textBackgroundColor) async -> RichCardPreview`

- [ ] **Step 1: Write the failing tests**

Append inside `RichTextRendererTests`, before the closing brace:

```swift
    // MARK: - Rasterisation

    /// The one end-to-end assertion: a black-backgrounded item must produce a bitmap that is
    /// actually black. Everything upstream can be right and still draw nothing.
    @MainActor
    func test_rasterised_preview_is_filled_with_the_dominant_background() async {
        let size = CGSize(width: 232, height: 154)
        let preview = await RichTextRenderer.cardPreview(
            for: terminalFixture(), size: size, defaultFill: .white)

        guard let image = preview.image else { return XCTFail("expected a rasterised preview") }
        XCTAssertEqual(image.size.width, size.width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, size.height, accuracy: 0.5)
        assertSimilar(preview.fill, .black)

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return XCTFail("could not read the bitmap back")
        }
        // Inside the 12pt padding, so it is fill and never a glyph.
        let corner = rep.colorAt(x: 2, y: 2)
        assertSimilar(corner, .black, tolerance: 0.1)

        // The corner alone proves only that the fill rendered: a bitmap with no text drawn at
        // all, or one where an opaque fill was painted over the glyphs, reads the same black
        // there. Scan for any pixel that is not the fill — that is what proves glyphs exist.
        // Scanned rather than sampled at a computed coordinate: the bitmap is retina-backed, so
        // its pixel dimensions exceed the point size and any fixed coordinate would be both
        // scale- and font-dependent.
        guard let fill = NSColor.black.usingColorSpace(.sRGB) else {
            return XCTFail("could not convert the fill colour")
        }
        var nonFillPixels = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // 0.2 sits well above the ~0.08 colour-table round-tripping noise `assertSimilar`
                // absorbs, and well below the near-saturated white/green/yellow-on-black deltas
                // this fixture actually produces.
                if abs(px.redComponent - fill.redComponent) > 0.2
                    || abs(px.greenComponent - fill.greenComponent) > 0.2
                    || abs(px.blueComponent - fill.blueComponent) > 0.2 {
                    nonFillPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(nonFillPixels, 0,
            "the bitmap contains only its fill colour, so no text was drawn onto it")
    }

    @MainActor
    func test_unbacked_item_still_rasterises_on_the_default_fill() async {
        let preview = await RichTextRenderer.cardPreview(
            for: mixedFixture(), size: CGSize(width: 232, height: 154), defaultFill: .white)
        XCTAssertNotNil(preview.image, "styled text is worth drawing even without a fill")
        XCTAssertNil(preview.fill, "no run background won, so the card keeps its default fill")
    }

    @MainActor
    func test_plain_item_yields_the_plain_decision() async {
        let plain = ClipboardItem(type: .text, text: "just text")
        let preview = await RichTextRenderer.cardPreview(
            for: plain, size: CGSize(width: 232, height: 154), defaultFill: .white)
        XCTAssertNil(preview.image)
        XCTAssertNil(preview.fill)
    }

    @MainActor
    func test_illegible_item_yields_the_plain_decision() async {
        // White text, no background anywhere: rasterising this would give a blank card.
        let s = NSAttributedString(string: "invisible on white",
                                  attributes: [.foregroundColor: NSColor.white,
                                               .font: NSFont.systemFont(ofSize: 13)])
        let preview = await RichTextRenderer.cardPreview(
            for: rtfItem(s), size: CGSize(width: 232, height: 154), defaultFill: .white)
        XCTAssertNil(preview.image)
    }

    @MainActor
    func test_fill_is_nil_whenever_there_is_no_image() {
        XCTAssertNil(RichCardPreview(image: nil, fill: .black).fill,
                     "a fill without an image would tint a footer whose content is plain text")
    }

    func test_card_preview_size_is_the_content_rect() {
        XCTAssertEqual(RichTextRenderer.cardPreviewSize.width, PanelLayout.cardBaseWidth)
        XCTAssertEqual(RichTextRenderer.cardPreviewSize.height,
                       PanelLayout.cardBaseHeight - PanelLayout.cardHeaderHeight
                           - PanelLayout.cardFooterHeight)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/pikalong/xPaste && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/RichTextRendererTests 2>&1 | tail -30
```

Expected: compile failure, `cannot find 'RichCardPreview' in scope`.

- [ ] **Step 3: Add the shared footer height**

In `xPaste/App/AppDelegate.swift`, inside `enum PanelLayout`, immediately after the `cardHeaderHeight` declaration:

```swift
    /// Height of a card's footer strip (the character count and ⌘-number badge). Shared with
    /// `RichTextRenderer.cardPreviewSize` so the rasterised preview matches the content rect.
    static let cardFooterHeight: CGFloat = 30
```

- [ ] **Step 4: Add the card entry points**

Append to `xPaste/Services/RichTextRenderer.swift`, at the end of the file (outside the `enum`):

```swift
/// A card's rich preview, or the decision not to draw one.
///
/// `image == nil` means "draw plain text" — a negative result worth caching, so an item that
/// resolved to plain is never parsed again when it scrolls back into view.
final class RichCardPreview {
    let image: NSImage?
    /// nil means "use `NSColor.textBackgroundColor`". Always nil when `image` is nil: a fill
    /// without an image would tint a footer whose preview is plain text.
    let fill: NSColor?

    init(image: NSImage?, fill: NSColor?) {
        self.image = image
        self.fill = image == nil ? nil : fill
    }

    static let plain = RichCardPreview(image: nil, fill: nil)
}
```

And inside `enum RichTextRenderer`, after the `isLegible` function:

```swift
    // MARK: - Card previews

    /// Inset matching the plain `textPreview`'s padding, so switching between the two does not
    /// shift the text.
    static let cardPadding: CGFloat = 12

    static var cardPreviewSize: CGSize {
        CGSize(width: PanelLayout.cardBaseWidth,
               height: PanelLayout.cardBaseHeight
                   - PanelLayout.cardHeaderHeight
                   - PanelLayout.cardFooterHeight)
    }

    /// Always returns a decision, never nil — the caller caches either outcome.
    ///
    /// `defaultFill` is injectable because `NSColor.textBackgroundColor` resolves against the
    /// current appearance: white text with no background of its own is illegible in light mode
    /// but perfectly readable in dark. The app always passes the dynamic colour; tests pass a
    /// fixed one so their result does not depend on the machine's appearance.
    @MainActor
    static func cardPreview(for item: ClipboardItem,
                            size: CGSize,
                            defaultFill: NSColor = .textBackgroundColor) async -> RichCardPreview {
        let parsed: ParsedRich?
        if item.richType == NSPasteboard.PasteboardType.rtf.rawValue {
            parsed = await Task.detached(priority: .userInitiated) { parse(item) }.value
        } else {
            // The HTML importer is WebKit-backed and main-thread only.
            parsed = parse(item)
        }
        guard let parsed else { return .plain }

        let fill = resolveFill(runBackground: dominantBackground(of: parsed.text),
                               documentBackground: parsed.documentBackground)
        let effective = fill ?? defaultFill
        guard fill != nil || isLegible(parsed.text, on: effective) else { return .plain }

        let body = parsed.text.length > cardCharLimit
            ? parsed.text.attributedSubstring(from: NSRange(location: 0, length: cardCharLimit))
            : parsed.text
        guard let image = rasterise(body, fill: effective, size: size) else { return .plain }
        return RichCardPreview(image: image, fill: fill)
    }

    /// Lays the text out **once** into a bitmap.
    ///
    /// `lockFocusFlipped(true)` gives retina backing from the display and flipped coordinates, so
    /// the text flows downward from the top of the rect. A drawing-handler `NSImage` would re-run
    /// TextKit on every draw, which is the entire cost this is meant to avoid.
    @MainActor
    private static func rasterise(_ text: NSAttributedString,
                                  fill: NSColor,
                                  size: CGSize) -> NSImage? {
        guard size.width > 2 * cardPadding, size.height > 2 * cardPadding else { return nil }
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        fill.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        text.draw(with: NSRect(x: cardPadding, y: cardPadding,
                               width: size.width - 2 * cardPadding,
                               height: size.height - 2 * cardPadding),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        image.unlockFocus()
        return image
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
cd /Users/pikalong/xPaste && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/RichTextRendererTests 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, 23 tests run.

If `test_rasterised_preview_is_filled_with_the_dominant_background` reports a *white* corner, the fill is being drawn but overwritten, or `lockFocusFlipped` produced an unexpected coordinate space — check that `NSBezierPath(rect:).fill()` runs before `text.draw`, not after.

- [ ] **Step 6: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/Services/RichTextRenderer.swift xPaste/App/AppDelegate.swift xPasteTests/RichTextRendererTests.swift && git commit -m "Lay a card's formatted text out once into a bitmap

TextKit runs a single time per item; every later body pass is one Image draw.
Handing an AttributedString to SwiftUI's Text would re-measure on every
re-layout, for every visible card in the LazyHStack.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Drawing it on the card

**Files:**
- Modify: `xPaste/Views/ClipboardItemCard.swift` (cache, `.task`, `contentPreview`, `defaultFooter`, `isLightColor`)
- Test: `xPasteTests/RichTextRendererTests.swift` (append)

**Interfaces:**
- Consumes: `RichCardPreview`, `RichTextRenderer.cardPreview(for:size:)`, `RichTextRenderer.cardPreviewSize` from Task 2.
- Produces: `ClipboardItemCard.isLight(_ colour: NSColor) -> Bool` and `ClipboardItemCard.footerTextColor(on fill: NSColor?) -> Color`, both static and internal so tests can reach them.

- [ ] **Step 1: Write the failing tests**

Append inside `RichTextRendererTests`, before the closing brace:

```swift
    // MARK: - Footer contrast

    func test_footer_text_flips_with_the_fill_brightness() {
        XCTAssertTrue(ClipboardItemCard.isLight(.white))
        XCTAssertFalse(ClipboardItemCard.isLight(.black))
        XCTAssertEqual(ClipboardItemCard.footerTextColor(on: nil), Color.secondary,
                       "no fill means the footer keeps the system secondary colour")
        XCTAssertNotEqual(ClipboardItemCard.footerTextColor(on: .black), Color.secondary,
                          "a dark fill needs light footer text, not the system secondary")
        XCTAssertNotEqual(ClipboardItemCard.footerTextColor(on: .black),
                          ClipboardItemCard.footerTextColor(on: .white))
    }
```

Add `import SwiftUI` to the top of the test file, after `import AppKit`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/pikalong/xPaste && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/RichTextRendererTests 2>&1 | tail -30
```

Expected: compile failure, `type 'ClipboardItemCard' has no member 'isLight'`.

- [ ] **Step 3: Add the colour helpers**

In `xPaste/Views/ClipboardItemCard.swift`, replace the existing `isLightColor` function (near the end of the struct, currently `private func isLightColor(_ color: Color) -> Bool`) with:

```swift
    private func isLightColor(_ color: Color) -> Bool {
        Self.isLight(NSColor(color))
    }

    /// Whether `colour` is light enough that dark text reads better on it.
    static func isLight(_ colour: NSColor) -> Bool {
        guard let ns = colour.usingColorSpace(.deviceRGB) else { return true }
        let luminance = 0.2126 * ns.redComponent
                      + 0.7152 * ns.greenComponent
                      + 0.0722 * ns.blueComponent
        return luminance > 0.5
    }

    /// Footer text colour that stays readable on a card whose footer took a rich fill.
    static func footerTextColor(on fill: NSColor?) -> Color {
        guard let fill else { return .secondary }
        return isLight(fill) ? Color.black.opacity(0.55) : Color.white.opacity(0.7)
    }
```

- [ ] **Step 4: Add the cache and state**

In `xPaste/Views/ClipboardItemCard.swift`, after the `loadedImageCache` declaration (around line 51), add:

```swift
    /// Rich previews, positive and negative alike: an item that resolved to plain text is stored
    /// as `RichCardPreview.plain` so it is never parsed twice.
    private static let richPreviewCache: NSCache<NSUUID, RichCardPreview> = {
        let c = NSCache<NSUUID, RichCardPreview>(); c.countLimit = 120; return c
    }()
```

And alongside the other `@State` properties (after `@State private var pathImage: NSImage?`):

```swift
    @State private var richPreview: RichCardPreview?
```

- [ ] **Step 5: Populate it in `.task`**

In the `.task(id: item.id)` block, immediately after the `if let imageURL { … }` block closes and before the `// Only publish a colour that had to be computed.` comment, insert:

```swift
            // Built here, never in `body`: parsing RTF and laying it out is TextKit work, and a
            // card that did it per body pass would re-measure on every panel re-layout.
            if item.richData != nil,
               item.type == .text || item.type == .url,
               resolved.url == nil,
               detectedColor == nil {
                if let cached = Self.richPreviewCache.object(forKey: item.id as NSUUID) {
                    if richPreview == nil { richPreview = cached }
                } else {
                    let built = await RichTextRenderer.cardPreview(
                        for: item, size: RichTextRenderer.cardPreviewSize)
                    Self.richPreviewCache.setObject(built, forKey: item.id as NSUUID)
                    richPreview = built
                }
            }
```

- [ ] **Step 6: Draw it**

In `xPaste/Views/ClipboardItemCard.swift`, add these two computed properties immediately before `private var textPreview: some View`:

```swift
    /// The cached decision for this item. Reads the cache directly as well as `@State` so a card
    /// scrolled back into view draws its preview on the first body pass, not one pass later.
    private var resolvedRichPreview: RichCardPreview? {
        richPreview ?? Self.richPreviewCache.object(forKey: item.id as NSUUID)
    }

    /// The fill this card's preview and footer share, or nil to keep the default colours.
    private var richFill: NSColor? { resolvedRichPreview?.fill }

    /// The formatted preview when there is one, the plain text otherwise.
    @ViewBuilder
    private var richOrTextPreview: some View {
        if let image = resolvedRichPreview?.image {
            // No `.resizable()`: the bitmap was laid out at exactly this size, and stretching it
            // would distort the glyphs. Top-leading + clipped truncates the way the layout does.
            Image(nsImage: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            textPreview
        }
    }
```

In `contentPreview`, change the ZStack's base fill from

```swift
            Color(NSColor.textBackgroundColor)
```

to

```swift
            Color(nsColor: richFill ?? .textBackgroundColor)
```

Then replace both `textPreview` references inside `contentPreview` with `richOrTextPreview`:
1. the `case .url:` final `else` branch,
2. the `case .text:` final `else` branch.

There are exactly two. Leave the `textPreview` property itself in place — `richOrTextPreview` falls back to it. `colorPreview` and the path branches keep their precedence, so a copied `#000000` still shows its swatch and a copied path still shows its file icon.

- [ ] **Step 7: Tint the footer**

In `defaultFooter`, replace

```swift
        Text(footerLabel)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
```

with

```swift
        Text(footerLabel)
            .font(.system(size: 11))
            .foregroundColor(Self.footerTextColor(on: richFill))
```

and replace its

```swift
            .background(Color(NSColor.controlBackgroundColor))
```

with

```swift
            // Paste runs the fill through the footer too: a black card whose footer stayed grey
            // reads as a bar bolted onto the bottom.
            .background(Color(nsColor: richFill ?? .controlBackgroundColor))
```

Also replace the literal `30` in `defaultFooter`'s and `fileFooter`'s `.frame(height: 30)` with `PanelLayout.cardFooterHeight`, so the card and the rasteriser cannot drift apart.

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd /Users/pikalong/xPaste && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`. The whole suite runs here, not just the new file — `PanelPerformanceTests` and `ClipboardItemTests` must be unaffected.

- [ ] **Step 9: Look at it**

```bash
cd /private/tmp/claude-501/-Users-pikalong/daf0fc73-0fba-4cdc-9fbb-5377144b116d/scratchpad && ./setrich dark && sleep 2 && ./setrich mixed
```

Then build and run the Debug app, open the panel, and confirm against Paste's screenshots: the terminal item is black edge to edge including its footer, with green and yellow lines intact; the mixed item is white with a large red heading, a yellow highlight hugging its run, and a purple underlined line.

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

- [ ] **Step 10: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/Views/ClipboardItemCard.swift xPasteTests/RichTextRendererTests.swift && git commit -m "Show a card's real formatting instead of flattening it

A card drew plain black-on-white text while pasting the same item restored its
black background, so the card contradicted the paste.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: The preview popover

**Files:**
- Modify: `xPaste/Views/ItemPreviewWindow.swift`
- Modify: `xPaste/Services/RichTextRenderer.swift` (add `fullPreview`)
- Test: `xPasteTests/RichTextRendererTests.swift` (append)

**Interfaces:**
- Consumes: `ParsedRich`, `resolveFill`, `dominantBackground`, `isLegible` from Task 1.
- Produces:
  - `final class RichFullPreview` with `let text: NSAttributedString`, `let fill: NSColor?`
  - `@MainActor RichTextRenderer.fullPreview(for item: ClipboardItem, defaultFill: NSColor = .textBackgroundColor) -> RichFullPreview?`

- [ ] **Step 1: Write the failing tests**

Append inside `RichTextRendererTests`, before the closing brace:

```swift
    // MARK: - Popover previews

    @MainActor
    func test_full_preview_keeps_the_whole_string_and_the_fill() {
        guard let full = RichTextRenderer.fullPreview(
            for: terminalFixture(), defaultFill: .white) else {
            return XCTFail("expected a full preview")
        }
        XCTAssertEqual(full.text.string, terminalFixture().text,
                       "the popover shows everything, not the card's 1500-character slice")
        assertSimilar(full.fill, .black)
    }

    @MainActor
    func test_full_preview_is_nil_for_a_plain_item() {
        XCTAssertNil(RichTextRenderer.fullPreview(
            for: ClipboardItem(type: .text, text: "plain"), defaultFill: .white))
    }

    @MainActor
    func test_full_preview_respects_the_legibility_guard() {
        let s = NSAttributedString(string: "invisible on white",
                                  attributes: [.foregroundColor: NSColor.white,
                                               .font: NSFont.systemFont(ofSize: 13)])
        XCTAssertNil(RichTextRenderer.fullPreview(for: rtfItem(s), defaultFill: .white))
    }

    @MainActor
    func test_full_preview_survives_a_string_longer_than_the_card_limit() {
        let long = String(repeating: "x", count: RichTextRenderer.cardCharLimit + 500)
        let s = NSAttributedString(string: long, attributes: [
            .foregroundColor: NSColor.white, .backgroundColor: NSColor.black,
            .font: NSFont.systemFont(ofSize: 13)])
        guard let full = RichTextRenderer.fullPreview(for: rtfItem(s), defaultFill: .white) else {
            return XCTFail("expected a full preview")
        }
        XCTAssertEqual(full.text.length, RichTextRenderer.cardCharLimit + 500)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/pikalong/xPaste && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' -only-testing:xPasteTests/RichTextRendererTests 2>&1 | tail -30
```

Expected: compile failure, `type 'RichTextRenderer' has no member 'fullPreview'`.

- [ ] **Step 3: Add `fullPreview`**

Append to `xPaste/Services/RichTextRenderer.swift`, at the end of the file:

```swift
/// The full styled string for the preview popover.
final class RichFullPreview {
    let text: NSAttributedString
    let fill: NSColor?

    init(text: NSAttributedString, fill: NSColor?) {
        self.text = text
        self.fill = fill
    }
}
```

And inside `enum RichTextRenderer`, after `cardPreview(for:size:)`:

```swift
    /// The popover's counterpart to `cardPreview`: the whole string, untruncated, because a
    /// popover exists one at a time and is where the user goes to read the thing.
    ///
    /// Synchronous and main-actor: the parse happens once from the popover's `.task`, never from
    /// its `body`.
    @MainActor
    static func fullPreview(for item: ClipboardItem,
                            defaultFill: NSColor = .textBackgroundColor) -> RichFullPreview? {
        guard let parsed = parse(item) else { return nil }
        let fill = resolveFill(runBackground: dominantBackground(of: parsed.text),
                               documentBackground: parsed.documentBackground)
        guard fill != nil || isLegible(parsed.text, on: defaultFill) else { return nil }
        return RichFullPreview(text: parsed.text, fill: fill)
    }
```

- [ ] **Step 4: Add the text view**

At the end of `xPaste/Views/ItemPreviewWindow.swift`, after `WebPreview`, add:

```swift
/// A read-only `NSTextView` showing an item's formatted text.
///
/// TextKit directly rather than the card's cached bitmap: here the text has to be selectable and
/// scrollable, and only one popover exists at a time, so fidelity beats the bitmap's speed.
private struct RichTextPreview: NSViewRepresentable {
    let text: NSAttributedString
    let fill: NSColor?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = true
            view.textContainerInset = NSSize(width: 14, height: 14)
            view.textStorage?.setAttributedString(text)
        }
        apply(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView,
           view.textStorage?.isEqual(to: text) == false {
            view.textStorage?.setAttributedString(text)
        }
        apply(to: scroll)
    }

    private func apply(to scroll: NSScrollView) {
        let colour = fill ?? .textBackgroundColor
        scroll.backgroundColor = colour
        (scroll.documentView as? NSTextView)?.backgroundColor = colour
    }
}
```

- [ ] **Step 5: Use it**

In `PreviewPopoverContent`, add a state property next to `@State private var loadedImage: NSImage?`:

```swift
    @State private var richPreview: RichFullPreview?
```

Change the existing `.task(id: item.id) { await loadImageIfNeeded() }` on the body to:

```swift
        .task(id: item.id) {
            await loadImageIfNeeded()
            // Parsed here, not in `body`: a large RTF re-parsed per body pass would stutter the
            // popover for nothing.
            if item.type == .text || item.type == .url {
                richPreview = RichTextRenderer.fullPreview(for: item)
            }
        }
```

Replace the whole `textContent` property with:

```swift
    @ViewBuilder
    private var textContent: some View {
        if let rich = richPreview {
            RichTextPreview(text: rich.text, fill: rich.fill)
        } else {
            plainTextContent
        }
    }

    private var plainTextContent: some View {
        ScrollView {
            Text(item.displayText)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
```

The popover's footer keeps its plain character/word/line count — it counts the text, not its styling.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /Users/pikalong/xPaste && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: `** TEST SUCCEEDED **`, whole suite.

- [ ] **Step 7: Look at it**

Build and run Debug, open the panel, hover the terminal item and press Space. The popover must show the same black background with green/yellow lines, and dragging across the text must still select it.

- [ ] **Step 8: Commit**

```bash
cd /Users/pikalong/xPaste && git add xPaste/Views/ItemPreviewWindow.swift xPaste/Services/RichTextRenderer.swift xPasteTests/RichTextRendererTests.swift && git commit -m "Show formatting in the preview popover too

A card that draws its real styling next to a popover that flattens it just
moves the contradiction one keystroke away.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Verify the panel is still fast

**Files:**
- Modify: none expected. If the numbers regress, `RichTextRenderer.cardCharLimit` and the byte caps are the dials.

**Interfaces:**
- Consumes: the finished feature.
- Produces: a recorded measurement in the commit message.

- [ ] **Step 1: Build Debug**

```bash
cd /Users/pikalong/xPaste && xcodebuild -project xPaste.xcodeproj -scheme xPaste -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
```

- [ ] **Step 2: Measure the plain-text path**

The harness injects plain synthetic items, so this run proves nothing regressed for items with no formatting.

```bash
XPASTE_PERF=1 XPASTE_AUTOOPEN=5 XPASTE_COPIES=3 \
  ~/Library/Developer/Xcode/DerivedData/xPaste-gzzhgdrvluhlbkbridqtxdsusbnr/Build/Products/Debug/xPaste.app/Contents/MacOS/xPaste
```

Then, in another shell:

```bash
/usr/bin/log show --predicate 'subsystem == "com.user.xPaste"' --last 60s --info
```

Expected: panel open inside the 16–25ms band, 0–1 dropped frames.

- [ ] **Step 3: Measure with formatted items in history**

Fill the history with rich items first, then repeat the measurement — this is the path that parses and rasterises.

```bash
cd /private/tmp/claude-501/-Users-pikalong/daf0fc73-0fba-4cdc-9fbb-5377144b116d/scratchpad && for i in 1 2 3 4 5; do ./setrich dark; sleep 1.5; ./setrich mixed; sleep 1.5; done
```

```bash
XPASTE_PERF=1 XPASTE_AUTOOPEN=5 \
  ~/Library/Developer/Xcode/DerivedData/xPaste-gzzhgdrvluhlbkbridqtxdsusbnr/Build/Products/Debug/xPaste.app/Contents/MacOS/xPaste
```

```bash
/usr/bin/log show --predicate 'subsystem == "com.user.xPaste"' --last 60s --info
```

Expected: still inside the band. The first open after a cold start pays the rasterisation for the visible cards only; opens after that read the cache.

If it is outside the band, halve `cardCharLimit` to 750 and measure again. Do not accept a regression — speed is this project's first priority, and the fix is a smaller slice of text, not a slower panel.

- [ ] **Step 4: Run the full suite one more time**

```bash
cd /Users/pikalong/xPaste && xcodebuild test -project xPaste.xcodeproj -scheme xPaste -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit the measurement**

```bash
cd /Users/pikalong/xPaste && git commit --allow-empty -m "Record the open-path measurement for rich cards

Plain path: <measured>ms. With formatted items in history: <measured>ms.
Band to hold: 16-25ms.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

Replace both `<measured>` values with the numbers actually read from the log. If either falls outside the band, do not commit this — go back to Step 3's dial.

- [ ] **Step 6: Manual checklist**

Verify by hand, since none of it is unit-testable:

1. A card copied from a dark terminal is black edge to edge, footer included.
2. A card copied from a light document is unchanged from before this work.
3. A copied colour string (`#1e90ff`) still shows its swatch, not styled text.
4. A copied file path still shows its file icon or thumbnail.
5. A copied link still shows its link preview and URL footer.
6. Pasting any of the above still lands with the same formatting it always did.
7. Renaming a card (double-click the title) still works over a rich preview.
8. The pin and delete hover buttons are still visible over a black card.
