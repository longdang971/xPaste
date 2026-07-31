import XCTest
import AppKit
import SwiftUI
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

    // MARK: - The HTML importer's default font
    //
    // A fragment copied out of a browser carries the page's markup but not the page's stylesheet,
    // so most of the time nothing in it names a font at all. Left alone, the WebKit importer then
    // falls back to its own default — Times-Roman 12 — and a card drawn from a sans-serif web page
    // comes out in a serif the user never saw.

    /// Every font on `text`, in run order.
    private func fontNames(of text: NSAttributedString) -> [String] {
        var names: [String] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length),
                                options: []) { value, _, _ in
            names.append((value as? NSFont)?.fontName ?? "<none>")
        }
        return names
    }

    private func htmlItem(_ html: String, text: String = "x") -> ClipboardItem {
        ClipboardItem(type: .text, text: text,
                      richData: Data(html.utf8),
                      richType: NSPasteboard.PasteboardType.html.rawValue)
    }

    func test_html_naming_no_font_does_not_fall_back_to_times() {
        let parsed = RichTextRenderer.parse(htmlItem("<meta charset='utf-8'>Xuất trong em"))
        guard let parsed else { return XCTFail("HTML did not parse") }
        for name in fontNames(of: parsed.text) {
            XCTAssertFalse(name.hasPrefix("Times"),
                           "unstyled HTML fell back to the importer's serif default: \(name)")
        }
    }

    func test_html_bold_run_without_a_font_stays_in_the_default_family() {
        let parsed = RichTextRenderer.parse(htmlItem("<meta charset='utf-8'>abc <b>đậm</b> def"))
        guard let parsed else { return XCTFail("HTML did not parse") }
        let names = fontNames(of: parsed.text)
        XCTAssertEqual(names.count, 3, "expected plain/bold/plain runs, got \(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix("Times") }, "\(names)")
    }

    /// The substitution is a *default*, so anything the fragment does name must still win.
    func test_html_that_names_a_font_keeps_it() {
        let html = "<meta charset='utf-8'><span style=\"font-family:Georgia,serif;font-size:20px\">Xuất</span>"
        guard let parsed = RichTextRenderer.parse(htmlItem(html)) else {
            return XCTFail("HTML did not parse")
        }
        let font = parsed.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, "Georgia")
        XCTAssertEqual(font?.pointSize, 20)
    }

    func test_html_monospaced_code_keeps_its_monospaced_font() {
        guard let parsed = RichTextRenderer.parse(
            htmlItem("<meta charset='utf-8'><pre><code>let x = 1</code></pre>")) else {
            return XCTFail("HTML did not parse")
        }
        let font = parsed.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontName, "Courier")
    }

    /// The prelude must not disturb anything else the importer reads off the fragment.
    func test_the_default_font_does_not_disturb_run_backgrounds() {
        let html = "<meta charset='utf-8'><span style=\"background-color:#000000;color:#ffffff\">dark run</span>"
        guard let parsed = RichTextRenderer.parse(htmlItem(html, text: "dark run")) else {
            return XCTFail("HTML did not parse")
        }
        XCTAssertEqual(parsed.text.string, "dark run")
        assertSimilar(RichTextRenderer.dominantBackground(of: parsed.text), .black)
    }

    /// The cap is there to bound the WebKit importer's work, so it has to be measured against
    /// what the source actually sent, not against the prelude we bolt on.
    func test_the_prelude_does_not_count_towards_the_html_cap() {
        let body = String(repeating: "a", count: RichTextRenderer.htmlByteCap)
        let item = htmlItem(body, text: body)
        XCTAssertNotNil(RichTextRenderer.parse(item))
        XCTAssertNil(RichTextRenderer.parse(htmlItem(body + "a", text: body)))
    }

    /// RTF always ships a font table, so it must be handed to the parser untouched.
    func test_rtf_fonts_are_left_alone() {
        let parsed = RichTextRenderer.parse(terminalFixture())
        guard let parsed else { return XCTFail("RTF did not parse") }
        let font = parsed.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.isFixedPitch == true, "monospaced RTF lost its font: \(font as Any)")
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

    func test_text_carrying_its_own_background_cannot_be_illegible_on_the_fill() {
        // Black glyphs, but sat on their own yellow highlight: they never touch the card's fill,
        // so no fill can hide them. Tallying them against the fill is measuring the wrong pair.
        let s = NSAttributedString(string: "highlighted",
                                   attributes: [.foregroundColor: NSColor.black,
                                                .backgroundColor: NSColor.systemYellow])
        XCTAssertTrue(RichTextRenderer.isLegible(s, on: .black))
    }

    func test_a_highlighted_run_does_not_flatten_the_rest_of_a_dark_card() {
        // The observed bug: the mixed fixture renders in full in light mode, but in dark mode its
        // one black-on-yellow run won the foreground tally, was compared against the dark card
        // fill, and dropped the whole item — heading, colours, highlight and all — to plain text.
        let parsed = RichTextRenderer.parse(mixedFixture())!
        XCTAssertTrue(
            RichTextRenderer.isLegible(parsed.text,
                                       on: RichTextRenderer.defaultFill(forLightAppearance: false)),
            "the runs that actually sit on the dark fill are a red heading, a blue line and a "
                + "purple line, every one of them readable")
    }

    @MainActor
    func test_the_mixed_item_stays_rich_in_dark_mode() async {
        // The same assertion at the level the user sees: light and dark must show the same card.
        let size = CGSize(width: 232, height: 154)
        let dark = await RichTextRenderer.cardPreview(
            for: mixedFixture(), size: size,
            defaultFill: RichTextRenderer.defaultFill(forLightAppearance: false))
        XCTAssertNotNil(dark.image, "dark mode flattened an item that light mode draws in full")
    }

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

        // The corner alone only proves the fill rendered. Scan the whole bitmap for pixels that
        // are clearly not fill-coloured, which is the only thing that can prove a glyph was
        // actually drawn: a missing `text.draw` call, or a fill painted on top of the text,
        // would both still pass every assertion above while leaving the bitmap uniformly black.
        guard let fillSRGB = NSColor.black.usingColorSpace(.sRGB) else {
            return XCTFail("could not convert the fill colour to sRGB")
        }
        let tolerance: CGFloat = 0.2
        var nonFillPixelCount = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let differs = abs(pixel.redComponent - fillSRGB.redComponent) > tolerance ||
                    abs(pixel.greenComponent - fillSRGB.greenComponent) > tolerance ||
                    abs(pixel.blueComponent - fillSRGB.blueComponent) > tolerance
                if differs { nonFillPixelCount += 1 }
            }
        }
        XCTAssertGreaterThan(nonFillPixelCount, 0,
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

    // MARK: - Colour swatch cards

    func test_glyphs_on_a_colour_swatch_tint_with_its_brightness() {
        // A swatch card carries no footer strip, so the hex label and the command-number badge are
        // both drawn straight onto the colour. One rule for both, or they disagree about whether
        // the colour behind them is light and one of the two sinks into it.
        XCTAssertEqual(ClipboardItemCard.onSwatchTint(.systemYellow), Color.black.opacity(0.65),
                       "a light swatch needs dark glyphs")
        XCTAssertEqual(ClipboardItemCard.onSwatchTint(.black), Color.white.opacity(0.85),
                       "a dark swatch needs light ones")
    }

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
        // Distinct is not enough: swapping the two would still pass everything above while
        // putting white footer text on a white card. Pin which colour goes with which fill.
        XCTAssertEqual(ClipboardItemCard.footerTextColor(on: .black), Color.white.opacity(0.7),
                       "a dark fill must take the light footer text")
        XCTAssertEqual(ClipboardItemCard.footerTextColor(on: .white), Color.black.opacity(0.55),
                       "a light fill must take the dark footer text")
    }

    /// The hover buttons sit on `.ultraThinMaterial`, which renders dark grey over a black card —
    /// `.secondary` disappears into it, and the icon that disappears is delete.
    func test_hover_icons_are_tinted_against_the_card_fill() {
        XCTAssertEqual(ClipboardItemCard.hoverIconColor(on: nil), Color.secondary,
                       "a card with no rich fill keeps the icons it always had")
        XCTAssertEqual(ClipboardItemCard.hoverIconColor(on: .black), Color.white.opacity(0.92),
                       "a black card needs near-white icons")
        XCTAssertEqual(ClipboardItemCard.hoverIconColor(on: .white), Color.black.opacity(0.7),
                       "a white card needs dark icons")
    }

    // MARK: - Appearance
    //
    // A card's rich preview is a baked bitmap, and an item with no run background of its own is
    // painted with the *resolved* `textBackgroundColor` — white in light mode, near-black in dark.
    // The legibility verdict is decided against that same fill. Both therefore belong to one
    // appearance, and a flip has to rebuild them rather than keep showing the old pixels.

    private func whiteTextItem() -> ClipboardItem {
        // No background anywhere: illegible on a light default fill, perfectly readable on a dark
        // one. This is the item whose *verdict* — not just its bitmap — depends on the appearance.
        rtfItem(NSAttributedString(string: "white words on nothing",
                                  attributes: [.foregroundColor: NSColor.white,
                                               .font: NSFont.systemFont(ofSize: 13)]))
    }

    @MainActor
    func test_card_preview_records_the_appearance_it_was_built_for() async {
        let size = CGSize(width: 232, height: 154)
        let light = await RichTextRenderer.cardPreview(
            for: terminalFixture(), size: size, forLightAppearance: true, defaultFill: .white)
        let dark = await RichTextRenderer.cardPreview(
            for: terminalFixture(), size: size, forLightAppearance: false, defaultFill: .black)

        XCTAssertTrue(light.builtForLightAppearance)
        XCTAssertFalse(dark.builtForLightAppearance)
    }

    /// The plain decision is cached too, so it has to carry the appearance as well — otherwise a
    /// "draw plain text" verdict taken in light mode would stick after a flip to dark.
    @MainActor
    func test_the_plain_decision_records_the_appearance_too() async {
        let plain = await RichTextRenderer.cardPreview(
            for: ClipboardItem(type: .text, text: "just text"),
            size: CGSize(width: 232, height: 154),
            forLightAppearance: false, defaultFill: .black)
        XCTAssertNil(plain.image)
        XCTAssertFalse(plain.builtForLightAppearance)
    }

    /// The staleness rule itself: this is what the card's cache reader consults, so an entry from
    /// the other appearance is a miss rather than something to draw.
    @MainActor
    func test_an_entry_built_for_the_other_appearance_is_not_usable() async {
        let builtInLight = await RichTextRenderer.cardPreview(
            for: terminalFixture(), size: CGSize(width: 232, height: 154),
            forLightAppearance: true, defaultFill: .white)

        XCTAssertTrue(builtInLight.isUsable(underLightAppearance: true))
        XCTAssertFalse(builtInLight.isUsable(underLightAppearance: false),
                       "a light-mode entry must not be reused after a flip to dark")
    }

    /// Why the verdict cannot simply be cached forever: the same item is rich in one appearance
    /// and plain in the other. This is also finding 2 — the card and the popover now agree,
    /// because both decide against the fill of the appearance on screen.
    @MainActor
    func test_the_same_item_gets_opposite_verdicts_in_the_two_appearances() async {
        let size = CGSize(width: 232, height: 154)
        let item = whiteTextItem()

        let inLight = await RichTextRenderer.cardPreview(
            for: item, size: size, forLightAppearance: true, defaultFill: .white)
        let inDark = await RichTextRenderer.cardPreview(
            for: item, size: size, forLightAppearance: false, defaultFill: .black)

        XCTAssertNil(inLight.image, "white text on a white default fill would be a blank card")
        XCTAssertNotNil(inDark.image, "the same text is perfectly readable on a dark default fill")
        // And the popover, which recomputes live, reaches the same two conclusions.
        XCTAssertNil(RichTextRenderer.fullPreview(for: item, defaultFill: .white))
        XCTAssertNotNil(RichTextRenderer.fullPreview(for: item, defaultFill: .black))
    }

    /// The bitmap of an unbacked item is painted with the default fill, so the pixels really do
    /// differ between the two appearances — the stale-bitmap bug this guards against.
    @MainActor
    func test_an_unbacked_item_rasterises_a_different_fill_per_appearance() async {
        let size = CGSize(width: 232, height: 154)
        // Mid-grey text, no background: unlike the fixtures above it clears the contrast floor
        // against both defaults, so the *only* difference between the two bitmaps is the fill.
        let item = rtfItem(NSAttributedString(string: "grey words on nothing", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        ]))
        let light = await RichTextRenderer.cardPreview(
            for: item, size: size, forLightAppearance: true, defaultFill: .white)
        let dark = await RichTextRenderer.cardPreview(
            for: item, size: size, forLightAppearance: false,
            defaultFill: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))

        guard let lightCorner = cornerColour(of: light.image),
              let darkCorner = cornerColour(of: dark.image) else {
            return XCTFail("expected both appearances to rasterise")
        }
        XCTAssertTrue(ClipboardItemCard.isLight(lightCorner))
        XCTAssertFalse(ClipboardItemCard.isLight(darkCorner))
    }

    func test_default_fill_follows_the_appearance_it_is_asked_for() {
        XCTAssertTrue(ClipboardItemCard.isLight(
            RichTextRenderer.defaultFill(forLightAppearance: true)),
            "the light appearance's text background is a light colour")
        XCTAssertFalse(ClipboardItemCard.isLight(
            RichTextRenderer.defaultFill(forLightAppearance: false)),
            "the dark appearance's text background is a dark colour")
    }

    /// `.task(id:)` takes one Equatable value, so the card combines the item and the appearance
    /// into this key. If it compared equal across a flip the task would never re-run.
    func test_card_task_key_changes_with_the_appearance() {
        let id = UUID()
        XCTAssertEqual(CardTaskKey(itemID: id, isLightAppearance: true),
                       CardTaskKey(itemID: id, isLightAppearance: true))
        XCTAssertNotEqual(CardTaskKey(itemID: id, isLightAppearance: true),
                          CardTaskKey(itemID: id, isLightAppearance: false))
        XCTAssertNotEqual(CardTaskKey(itemID: id, isLightAppearance: true),
                          CardTaskKey(itemID: UUID(), isLightAppearance: true))
    }

    /// Inside the 12pt padding, so it is fill and never a glyph.
    private func cornerColour(of image: NSImage?) -> NSColor? {
        guard let image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB)
    }

    // MARK: - Truncation

    /// `cardCharLimit` bounds the TextKit work a card pays for, and deleting it would leave every
    /// other test green — the limit is far more text than a card can show at a normal font size,
    /// so it is invisible in a normal bitmap.
    ///
    /// Tiny type is what makes it observable: at 2pt roughly 26,000 characters fit in the content
    /// rect, so a 30,000-character string would fill the bitmap to the bottom if it were drawn
    /// whole, while the truncated 1,500 characters occupy only the first few lines. Assert both
    /// halves: glyphs near the top, nothing but fill in the bottom half.
    @MainActor
    func test_card_preview_truncates_at_the_character_limit() async {
        let size = CGSize(width: 232, height: 154)
        let long = String(repeating: "truncation ", count: 3_000) // 33,000 characters
        XCTAssertGreaterThan(long.count, RichTextRenderer.cardCharLimit * 20)
        let s = NSAttributedString(string: long, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 2, weight: .regular),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black,
        ])

        let preview = await RichTextRenderer.cardPreview(
            for: rtfItem(s), size: size, forLightAppearance: true, defaultFill: .white)
        guard let image = preview.image, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return XCTFail("expected a rasterised preview")
        }
        guard let fill = NSColor.black.usingColorSpace(.sRGB) else {
            return XCTFail("could not convert the fill colour to sRGB")
        }
        func isGlyph(_ x: Int, _ y: Int) -> Bool {
            guard let px = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return abs(px.redComponent - fill.redComponent) > 0.2
                || abs(px.greenComponent - fill.greenComponent) > 0.2
                || abs(px.blueComponent - fill.blueComponent) > 0.2
        }

        var glyphRowsInTopQuarter = 0
        var glyphRowsInBottomHalf = 0
        for y in 0..<rep.pixelsHigh {
            var rowHasGlyph = false
            for x in 0..<rep.pixelsWide where isGlyph(x, y) { rowHasGlyph = true; break }
            guard rowHasGlyph else { continue }
            if y < rep.pixelsHigh / 4 { glyphRowsInTopQuarter += 1 }
            if y >= rep.pixelsHigh / 2 { glyphRowsInBottomHalf += 1 }
        }

        XCTAssertGreaterThan(glyphRowsInTopQuarter, 0,
            "the truncated slice should still have drawn text at the top of the bitmap")
        XCTAssertEqual(glyphRowsInBottomHalf, 0,
            "text reached the bottom half of the bitmap, so more than \(RichTextRenderer.cardCharLimit) characters were laid out")
    }

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
}
