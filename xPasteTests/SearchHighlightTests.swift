import XCTest
@testable import xPaste

/// Splitting a card's text into matched and unmatched runs, so the matched ones can be washed
/// yellow. The rule that matters most: the pieces must reassemble into the original string —
/// a highlighter that quietly drops or duplicates a character is worse than no highlighter.
final class SearchHighlightTests: XCTestCase {

    private func split(_ text: String, _ term: String) -> [(text: String, isMatch: Bool)] {
        SearchHighlight.split(text, term: term)
    }

    private func assertReassembles(_ text: String, _ term: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let joined = split(text, term).map(\.text).joined()
        XCTAssertEqual(joined, text, "the runs must reassemble into the original", file: file, line: line)
    }

    func test_no_term_leaves_the_text_whole() {
        let parts = split("adobe.com/express/blog", "")
        XCTAssertEqual(parts.count, 1)
        XCTAssertFalse(parts[0].isMatch)
        XCTAssertEqual(parts[0].text, "adobe.com/express/blog")
    }

    func test_a_term_that_is_not_there_leaves_the_text_whole() {
        let parts = split("adobe.com", "figma")
        XCTAssertEqual(parts.count, 1)
        XCTAssertFalse(parts[0].isMatch)
    }

    func test_a_hit_in_the_middle_splits_into_three() {
        let parts = split("adobe.com/blog/pitch-deck/x", "pitch-deck")
        XCTAssertEqual(parts.map(\.text), ["adobe.com/blog/", "pitch-deck", "/x"])
        XCTAssertEqual(parts.map(\.isMatch), [false, true, false])
    }

    func test_a_hit_at_either_end_produces_no_empty_run() {
        // An empty run would mean an empty AttributedString piece for nothing.
        XCTAssertEqual(split("pitch-deck/x", "pitch-deck").map(\.text), ["pitch-deck", "/x"])
        XCTAssertEqual(split("x/pitch-deck", "pitch-deck").map(\.text), ["x/", "pitch-deck"])
        XCTAssertEqual(split("pitch", "pitch").map(\.text), ["pitch"])
        XCTAssertEqual(split("pitch", "pitch").map(\.isMatch), [true])
    }

    func test_every_occurrence_is_marked() {
        let parts = split("deck deck deck", "deck")
        XCTAssertEqual(parts.filter(\.isMatch).count, 3)
        assertReassembles("deck deck deck", "deck")
    }

    /// The search matches with `localizedCaseInsensitiveContains`, so the highlight has to match
    /// the same way — otherwise a card appears in the results with nothing painted on it.
    func test_matching_ignores_case_the_way_the_search_does() {
        let parts = split("Best Fonts for Presentations", "fonts")
        XCTAssertEqual(parts.map(\.text), ["Best ", "Fonts", " for Presentations"])
        XCTAssertTrue(parts[1].isMatch)
    }

    func test_vietnamese_text_matches_and_reassembles() {
        let text = "Chén em gái đẹp hàng mup"
        let parts = split(text, "ĐẸP")
        XCTAssertEqual(parts.filter(\.isMatch).map(\.text), ["đẹp"],
                       "the run kept must be the text's own casing, not the term's")
        assertReassembles(text, "ĐẸP")
    }

    func test_a_term_with_a_space_is_matched_whole() {
        // Free text arrives joined by spaces, so "pitch deck" is one term, not two.
        let parts = split("a pitch deck b", "pitch deck")
        XCTAssertEqual(parts.map(\.text), ["a ", "pitch deck", " b"])
    }

    // MARK: - Positions for the baked bitmap

    /// A formatted card's highlight is applied to an `NSAttributedString` before it is rasterised,
    /// and `NSAttributedString` counts in UTF-16 units. Anything outside the BMP — an emoji, most
    /// obviously — makes UTF-16 offsets diverge from character offsets, and a wrong offset paints
    /// the wash over the wrong glyphs rather than failing loudly.
    func test_positions_are_counted_in_utf16_units() {
        XCTAssertEqual(SearchHighlight.nsRanges(of: "pitch", in: "abc pitch def"),
                       [NSRange(location: 4, length: 5)])
        XCTAssertEqual(SearchHighlight.nsRanges(of: "pitch", in: "🎉 pitch"),
                       [NSRange(location: 3, length: 5)],
                       "the emoji is one character but two UTF-16 units")
        XCTAssertEqual(SearchHighlight.nsRanges(of: "deck", in: "🎉🎉 deck deck"),
                       [NSRange(location: 5, length: 4), NSRange(location: 10, length: 4)])
    }

    func test_no_positions_without_a_term_or_a_hit() {
        XCTAssertEqual(SearchHighlight.nsRanges(of: "", in: "abc"), [])
        XCTAssertEqual(SearchHighlight.nsRanges(of: "zzz", in: "abc"), [])
    }

    /// One source for the colour, used by both the plain `Text` path and the baked bitmap. If the
    /// two computed it separately they would drift, and the same search would paint two different
    /// yellows on two cards sitting side by side.
    func test_the_dark_wash_is_translucent_and_the_light_one_is_not() {
        XCTAssertEqual(SearchHighlight.fill(forLightAppearance: true).alphaComponent, 1.0,
                       accuracy: 0.001, "a white card takes the solid yellow")
        XCTAssertLessThan(SearchHighlight.fill(forLightAppearance: false).alphaComponent, 0.5,
                          "a dark panel takes a wash, not a plate punched through the text")
    }

    // MARK: - Marking formatted text

    private func background(_ s: NSAttributedString, at location: Int) -> NSColor? {
        s.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    func test_a_hit_in_unstyled_text_gets_the_solid_wash() {
        let marked = SearchHighlight.marked(NSAttributedString(string: "abc pitch def"),
                                            term: "pitch", forLightAppearance: true)
        XCTAssertEqual(background(marked, at: 4)?.alphaComponent, 1.0)
        XCTAssertNil(background(marked, at: 0), "text outside the hit keeps what it had")
    }

    /// A terminal transcript comes back as light text on a dark run background — in light mode as
    /// well as dark. Painting solid yellow over that run buries its own text colour: pale glyphs on
    /// a bright plate, which is less readable than no highlight at all.
    func test_a_hit_over_a_coloured_run_gets_a_translucent_wash_instead() {
        let styled = NSMutableAttributedString(string: "abc pitch def")
        styled.addAttribute(.backgroundColor, value: NSColor.black,
                            range: NSRange(location: 4, length: 5))

        let marked = SearchHighlight.marked(styled, term: "pitch", forLightAppearance: true)
        let wash = background(marked, at: 4)
        XCTAssertNotNil(wash)
        XCTAssertLessThan(wash!.alphaComponent, 0.5,
                          "the run's own colour has to show through the mark")
    }

    func test_marking_leaves_text_with_no_hit_alone() {
        let original = NSAttributedString(string: "abc def")
        let marked = SearchHighlight.marked(original, term: "zzz", forLightAppearance: true)
        XCTAssertEqual(marked.string, original.string)
        XCTAssertNil(background(marked, at: 0))
    }

    func test_marking_lands_on_the_right_glyphs_past_an_emoji() {
        let marked = SearchHighlight.marked(NSAttributedString(string: "🎉 pitch"),
                                            term: "pitch", forLightAppearance: true)
        XCTAssertNil(background(marked, at: 0), "the emoji must not be washed")
        XCTAssertNotNil(background(marked, at: 3))
    }

    // MARK: - Cache identity

    /// The mark is drawn into the pixels, so a bitmap baked for one term must not be shown for
    /// another — otherwise typing a second character would leave the first character's highlight
    /// on screen with nothing rebuilding it.
    func test_a_baked_bitmap_belongs_to_its_term_and_appearance() {
        let entry = RichCardPreview(image: NSImage(size: NSSize(width: 1, height: 1)), fill: nil,
                                    builtForLightAppearance: true, builtForTerm: "pitch")
        XCTAssertTrue(entry.isUsable(underLightAppearance: true, term: "pitch"))
        XCTAssertFalse(entry.isUsable(underLightAppearance: true, term: "pit"),
                       "a shorter term is a different bitmap, not a usable one")
        XCTAssertFalse(entry.isUsable(underLightAppearance: true, term: ""),
                       "clearing the search box has to drop the marked bitmap")
        XCTAssertFalse(entry.isUsable(underLightAppearance: false, term: "pitch"))
    }

    func test_an_unmarked_bitmap_is_the_default() {
        let entry = RichCardPreview(image: NSImage(size: NSSize(width: 1, height: 1)), fill: nil,
                                    builtForLightAppearance: true)
        XCTAssertTrue(entry.isUsable(underLightAppearance: true),
                      "no search running is the normal state and must hit the cache")
    }

    func test_odd_inputs_do_not_hang_or_mangle() {
        XCTAssertEqual(split("", "x").map(\.text), [""])
        XCTAssertEqual(split("ab", "abcdef").map(\.isMatch), [false])
        assertReassembles("aaaa", "aa")
        assertReassembles("café", "e")
    }
}
