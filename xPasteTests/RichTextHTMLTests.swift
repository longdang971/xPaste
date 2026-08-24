import XCTest
import AppKit
@testable import xPaste

/// The markup raw mode shows, and the parse that takes it back.
///
/// The rules under test are not matters of taste — they were measured against Cocoa's HTML
/// importer, and the measurements are named in the test that pins each one.
final class RichTextHTMLTests: XCTestCase {

    private let plain: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor.labelColor,
    ]

    // MARK: - Writing

    func test_plain_text_becomes_one_paragraph_with_nothing_added() {
        let text = NSAttributedString(string: "hello", attributes: plain)
        XCTAssertEqual(RichTextHTML.html(from: text), "<p>hello</p>")
    }

    /// One `<p>` per line, because that is what the importer reverses exactly. See
    /// `test_the_plain_string_survives_a_round_trip_including_its_newlines`.
    func test_each_line_becomes_its_own_paragraph() {
        let text = NSAttributedString(string: "a\nb", attributes: plain)
        XCTAssertEqual(RichTextHTML.html(from: text), "<p>a</p>\n<p>b</p>")
    }

    func test_a_trailing_newline_becomes_an_empty_final_paragraph() {
        let text = NSAttributedString(string: "a\n", attributes: plain)
        XCTAssertEqual(RichTextHTML.html(from: text), "<p>a</p>\n<p></p>")
    }

    func test_an_empty_string_is_an_empty_paragraph() {
        XCTAssertEqual(RichTextHTML.html(from: NSAttributedString(string: "")), "<p></p>")
    }

    /// The system font is written as `<b>`, never as a `font-family`: its family name is the
    /// private `.AppleSystemUIFont`, which is not something to put in a stylesheet.
    func test_bold_system_text_is_a_b_tag_with_no_font_family() {
        let bold = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13),
                                                toHaveTrait: .boldFontMask)
        let text = NSMutableAttributedString(string: "hi there", attributes: plain)
        text.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 2))
        let html = RichTextHTML.html(from: text)
        XCTAssertEqual(html, "<p><b>hi</b> there</p>")
        XCTAssertFalse(html?.contains("font-family") ?? true)
    }

    func test_italic_system_text_is_an_i_tag() {
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13),
                                                  toHaveTrait: .italicFontMask)
        let text = NSAttributedString(string: "hi", attributes: [.font: italic])
        XCTAssertEqual(RichTextHTML.html(from: text), "<p><i>hi</i></p>")
    }

    func test_underline_and_strikethrough_are_tags() {
        let under = NSAttributedString(string: "u", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let struck = NSAttributedString(string: "s", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ])
        XCTAssertEqual(RichTextHTML.html(from: under), "<p><u>u</u></p>")
        XCTAssertEqual(RichTextHTML.html(from: struck), "<p><s>s</s></p>")
    }

    /// A face other than the system one is named by its **PostScript** name. A family plus
    /// `font-weight` does not survive the importer: 'Helvetica Neue' at font-weight:500 returns as
    /// HelveticaNeue-Medium and at 600 as Bold.
    func test_a_non_system_face_is_named_by_its_postscript_name() {
        let menlo = NSFont(name: "Menlo-Regular", size: 20)!
        let text = NSAttributedString(string: "x", attributes: [.font: menlo])
        XCTAssertEqual(RichTextHTML.html(from: text),
                       "<p><span style=\"font-family:Menlo-Regular;font-size:20px\">x</span></p>")
    }

    /// The PostScript name already carries the traits, so adding `<b>` on top would say it twice.
    func test_a_bold_non_system_face_carries_its_bold_in_the_name_not_a_tag() {
        let bold = NSFont(name: "Menlo-Bold", size: 13)!
        let html = RichTextHTML.html(from: NSAttributedString(string: "x", attributes: [.font: bold]))
        XCTAssertEqual(html, "<p><span style=\"font-family:Menlo-Bold;font-size:13px\">x</span></p>")
        XCTAssertFalse(html?.contains("<b>") ?? true)
    }

    /// 13 is what the prelude gives anything the markup does not style, so it needs no `font-size`.
    func test_the_default_size_is_left_unwritten_but_any_other_size_is_not() {
        let thirteen = NSAttributedString(string: "x", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let twenty = NSAttributedString(string: "x", attributes: [.font: NSFont.systemFont(ofSize: 20)])
        XCTAssertEqual(RichTextHTML.html(from: thirteen), "<p>x</p>")
        XCTAssertEqual(RichTextHTML.html(from: twenty), "<p><span style=\"font-size:20px\">x</span></p>")
    }

    func test_colours_are_written_as_hex() {
        let text = NSAttributedString(string: "x", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            .backgroundColor: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
        ])
        XCTAssertEqual(RichTextHTML.html(from: text),
                       "<p><span style=\"color:#ff0000;background-color:#00ff00\">x</span></p>")
    }

    /// `labelColor` is the editor's default and is dynamic — writing out the colour it happens to
    /// resolve to would freeze dark-mode white into the source.
    func test_the_default_label_colour_is_left_unwritten() {
        let text = NSAttributedString(string: "x", attributes: plain)
        XCTAssertEqual(RichTextHTML.html(from: text), "<p>x</p>")
    }

    func test_a_link_becomes_an_anchor() {
        let text = NSAttributedString(string: "vidu", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .link: URL(string: "https://vidu.com")!,
        ])
        XCTAssertEqual(RichTextHTML.html(from: text),
                       "<p><a href=\"https://vidu.com\">vidu</a></p>")
    }

    /// The importer paints links blue and underlines them itself. Writing that styling back out
    /// would bake the importer's own decision a little deeper into the source on every round trip.
    func test_a_links_own_blue_and_underline_are_not_written_back_out() {
        let text = NSAttributedString(string: "vidu", attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .link: URL(string: "https://vidu.com")!,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        let html = RichTextHTML.html(from: text)
        XCTAssertEqual(html, "<p><a href=\"https://vidu.com\">vidu</a></p>")
        XCTAssertFalse(html?.contains("<u>") ?? true)
        XCTAssertFalse(html?.contains("color:") ?? true)
    }

    func test_markup_characters_in_the_text_are_escaped() {
        let text = NSAttributedString(string: "a & b <tag> \"q\"", attributes: plain)
        XCTAssertEqual(RichTextHTML.html(from: text),
                       "<p>a &amp; b &lt;tag&gt; &quot;q&quot;</p>")
    }

    func test_something_larger_than_the_cap_is_refused() {
        let huge = NSAttributedString(string: String(repeating: "x", count: RichTextRenderer.htmlByteCap + 1),
                                      attributes: plain)
        XCTAssertNil(RichTextHTML.html(from: huge))
    }
}
