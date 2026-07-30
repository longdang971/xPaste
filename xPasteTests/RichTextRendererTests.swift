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
}
