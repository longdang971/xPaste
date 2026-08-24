import XCTest
import AppKit
@testable import xPaste

/// The content rules behind editing an item: what kind of item the edited text makes it, and how
/// formatting survives the trip out of the editor and back into storage.
final class ItemEditTests: XCTestCase {

    // MARK: - What the edited text makes the item

    func testHTTPAndHTTPSTextIsALink() {
        XCTAssertEqual(ClipboardItem.contentType(for: "https://example.com"), .url)
        XCTAssertEqual(ClipboardItem.contentType(for: "http://example.com/a?b=1"), .url)
    }

    func testSurroundingWhitespaceDoesNotStopSomethingBeingALink() {
        XCTAssertEqual(ClipboardItem.contentType(for: "  https://example.com \n"), .url)
    }

    /// Only the two schemes a link preview can actually fetch. A `mailto:` card that claimed to be
    /// a link would sit there waiting for a page that is never coming.
    func testOtherSchemesAndProseAreText() {
        XCTAssertEqual(ClipboardItem.contentType(for: "ftp://example.com"), .text)
        XCTAssertEqual(ClipboardItem.contentType(for: "mailto:a@example.com"), .text)
        XCTAssertEqual(ClipboardItem.contentType(for: "example.com"), .text)
        XCTAssertEqual(ClipboardItem.contentType(for: "just a sentence"), .text)
        XCTAssertEqual(ClipboardItem.contentType(for: ""), .text)
    }

    /// A link with anything after it is a piece of text that mentions a link, not a link.
    func testTextAroundALinkMakesItText() {
        XCTAssertEqual(ClipboardItem.contentType(for: "see https://example.com for more"), .text)
    }

    // MARK: - What can be edited

    func testTextAndLinksCanBeEdited() {
        XCTAssertTrue(ItemEdit.canEdit(.text))
        XCTAssertTrue(ItemEdit.canEdit(.url))
    }

    func testPicturesAndFilesCannotBeEdited() {
        XCTAssertFalse(ItemEdit.canEdit(.image))
        XCTAssertFalse(ItemEdit.canEdit(.file))
        XCTAssertFalse(ItemEdit.canEdit(.folder))
    }

    func testATextItemThatArrivedFormattedKeepsItsFormatting() {
        let rich = ClipboardItem(type: .text, text: "styled", richData: Data([1]), richType: "public.rtf")
        XCTAssertTrue(ItemEdit.keepsFormatting(rich))
    }

    /// The claim this used to make of `keepsFormatting` — that a plain item never starts storing
    /// RTF just for having been opened — now belongs to `carriesFormatting`. The editor offers a
    /// plain item formatting; only using some of it makes the item formatted.
    func testAPlainItemStaysPlainThroughTheEditorUnlessItIsActuallyFormatted() {
        let plain = ClipboardItem(type: .text, text: "plain")
        XCTAssertTrue(ItemEdit.keepsFormatting(plain))
        XCTAssertFalse(ItemEdit.carriesFormatting(ItemEdit.editorSeed(for: plain, parsed: nil).text))
    }

    /// A link is edited as the address it is, not as the styled anchor the browser put on the
    /// pasteboard beside it.
    func testALinkIsEditedAsPlainTextEvenWhenItCarriesFormatting() {
        let link = ClipboardItem(type: .url, text: "https://example.com",
                                 richData: Data([1]), richType: "public.html")
        XCTAssertFalse(ItemEdit.keepsFormatting(link))
    }

    // MARK: - What the editor opens with

    private func styledItem() -> ClipboardItem {
        let styled = NSMutableAttributedString(string: "release notes")
        styled.addAttribute(.backgroundColor, value: NSColor.yellow,
                            range: NSRange(location: 0, length: 7))
        return ClipboardItem(type: .text, text: "release notes",
                             richData: ItemEdit.rtf(from: styled), richType: ItemEdit.richType)
    }

    /// The race this exists to close: "Edit…" builds the editor from `onAppear`, a turn before the
    /// popover's `.task` has parsed anything. Seeded with the plain string, saving re-encoded that
    /// as RTF and flattened the very highlight the editor was opened to preserve.
    func testAFormattedItemNeverOpensOnAPlainCopyEvenBeforeTheParseLands() throws {
        let seed = ItemEdit.editorSeed(for: styledItem(), parsed: nil)

        XCTAssertTrue(seed.formatted)
        XCTAssertNotNil(seed.text.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                        "the editor opened on text with the formatting already gone")
    }

    func testTheParseInHandIsPreferredWhenThereIsOne() {
        let supplied = NSAttributedString(string: "already parsed")

        let seed = ItemEdit.editorSeed(for: styledItem(), parsed: supplied)

        XCTAssertEqual(seed.text.string, "already parsed")
        XCTAssertTrue(seed.formatted)
    }

    /// Formatting nobody can parse still opens on an editor that allows formatting — same as any
    /// other Text item — it just falls back to the plain string, because there is nothing else to
    /// seed the editor with.
    func testUnreadableFormattingStillOpensOnAnEditorThatAllowsFormatting() {
        let broken = ClipboardItem(type: .text, text: "hi",
                                   richData: Data([0x00, 0x01]), richType: "public.rtf")

        let seed = ItemEdit.editorSeed(for: broken, parsed: nil)
        XCTAssertTrue(seed.formatted)
        XCTAssertEqual(seed.text.string, "hi")
        // Even though the editor allows formatting, the fallback text is plain and must not be
        // mistaken for text that actually carries formatting.
        XCTAssertFalse(ItemEdit.carriesFormatting(seed.text))
    }

    // MARK: - Formatting out of the editor

    func testBoldAndAHighlightSurviveTheRoundTripThroughRTF() throws {
        let source = NSMutableAttributedString(string: "plain bold")
        source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13),
                            range: NSRange(location: 6, length: 4))
        source.addAttribute(.backgroundColor, value: NSColor.yellow,
                            range: NSRange(location: 6, length: 4))

        let data = try XCTUnwrap(ItemEdit.rtf(from: source))
        let restored = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))

        XCTAssertEqual(restored.string, "plain bold")
        let font = restored.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertNotNil(restored.attribute(.backgroundColor, at: 6, effectiveRange: nil))
    }

    func testAnEmptyStringHasNoFormattingToStore() {
        XCTAssertNil(ItemEdit.rtf(from: NSAttributedString(string: "")))
    }

    // MARK: - Revision

    /// Items already on disk were written before this field existed, and every one of them still
    /// has to decode.
    func testAnItemStoredBeforeRevisionsExistedLoadsAtZero() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","type":"text","text":"hi",
         "timestamp":760000000,"isPinned":false}
        """

        let item = try JSONDecoder().decode(ClipboardItem.self, from: Data(legacy.utf8))

        XCTAssertEqual(item.contentRevision, 0)
    }

    func testAStoredRevisionSurvivesARoundTrip() throws {
        var item = ClipboardItem(type: .text, text: "hi")
        item.revision = 3

        let restored = try JSONDecoder().decode(
            ClipboardItem.self, from: try JSONEncoder().encode(item))

        XCTAssertEqual(restored.contentRevision, 3)
    }

    // MARK: - Which items get a toolbar

    func test_every_text_item_opens_formatted_now_that_there_is_a_toolbar() {
        let plain = ClipboardItem(type: .text, text: "hello")
        let formatted = ClipboardItem(type: .text, text: "hello",
                                      richData: Data("x".utf8),
                                      richType: NSPasteboard.PasteboardType.rtf.rawValue)
        XCTAssertTrue(ItemEdit.keepsFormatting(plain))
        XCTAssertTrue(ItemEdit.keepsFormatting(formatted))
    }

    /// A Link is still edited as the address it is, not as the styled anchor a browser happened to
    /// put on the pasteboard.
    func test_a_link_is_still_edited_plain() {
        let link = ClipboardItem(type: .url, text: "https://example.com")
        XCTAssertFalse(ItemEdit.keepsFormatting(link))
        XCTAssertFalse(ItemEdit.editorSeed(for: link, parsed: nil).formatted)
    }

    func test_a_plain_text_item_opens_on_an_editor_that_allows_formatting() {
        let plain = ClipboardItem(type: .text, text: "hello")
        let seed = ItemEdit.editorSeed(for: plain, parsed: nil)
        XCTAssertTrue(seed.formatted)
        XCTAssertEqual(seed.text.string, "hello")
    }

    // MARK: - Whether an edit is worth storing as RTF

    /// The question is "does this differ from what it opened with?", never "does this have
    /// attributes?" — an NSTextView gives a default font to everything it is handed, so the second
    /// question answers yes for every plain snippet ever opened.
    func test_text_on_the_editors_own_defaults_carries_no_formatting() {
        let text = NSAttributedString(string: "hello", attributes: ItemEdit.plainDefaults)
        XCTAssertFalse(ItemEdit.carriesFormatting(text))
    }

    func test_text_with_no_attributes_at_all_carries_no_formatting() {
        XCTAssertFalse(ItemEdit.carriesFormatting(NSAttributedString(string: "hello")))
    }

    func test_one_bold_word_makes_the_whole_thing_formatted() {
        let bold = NSFontManager.shared.convert(ItemEdit.plainFont, toHaveTrait: .boldFontMask)
        let text = NSMutableAttributedString(string: "hi there", attributes: ItemEdit.plainDefaults)
        text.addAttribute(.font, value: bold, range: NSRange(location: 0, length: 2))
        XCTAssertTrue(ItemEdit.carriesFormatting(text))
    }

    func test_a_different_size_a_colour_a_highlight_a_link_or_a_rule_each_count() {
        func decorated(_ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
            var merged = ItemEdit.plainDefaults
            for (key, value) in attrs { merged[key] = value }
            return NSAttributedString(string: "x", attributes: merged)
        }
        XCTAssertTrue(ItemEdit.carriesFormatting(decorated([.font: NSFont.systemFont(ofSize: 24)])))
        XCTAssertTrue(ItemEdit.carriesFormatting(decorated([.foregroundColor: NSColor.systemRed])))
        XCTAssertTrue(ItemEdit.carriesFormatting(decorated([.backgroundColor: NSColor.systemYellow])))
        XCTAssertTrue(ItemEdit.carriesFormatting(decorated([.link: URL(string: "https://x.com")!])))
        XCTAssertTrue(ItemEdit.carriesFormatting(
            decorated([.underlineStyle: NSUnderlineStyle.single.rawValue])))
        XCTAssertTrue(ItemEdit.carriesFormatting(
            decorated([.strikethroughStyle: NSUnderlineStyle.single.rawValue])))
    }

    /// The whole reason a plain item is allowed near the rich editor at all: it has to come out the
    /// other side still plain unless the user actually formatted something.
    func test_a_plain_item_taken_through_raw_mode_and_back_is_still_plain() {
        let text = NSAttributedString(string: "hello\nworld", attributes: ItemEdit.plainDefaults)
        let html = try? XCTUnwrap(RichTextHTML.html(from: text))
        let back = try? XCTUnwrap(RichTextHTML.attributed(from: html ?? ""))
        XCTAssertEqual(back?.string, "hello\nworld")
        XCTAssertFalse(ItemEdit.carriesFormatting(back ?? NSAttributedString()))
    }
}
