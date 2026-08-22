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

    func testOnlyATextItemThatArrivedFormattedKeepsItsFormatting() {
        let rich = ClipboardItem(type: .text, text: "styled", richData: Data([1]), richType: "public.rtf")
        XCTAssertTrue(ItemEdit.keepsFormatting(rich))
    }

    func testAPlainItemStaysPlainThroughTheEditor() {
        XCTAssertFalse(ItemEdit.keepsFormatting(ClipboardItem(type: .text, text: "plain")))
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

    func testAPlainItemOpensPlain() {
        let seed = ItemEdit.editorSeed(for: ClipboardItem(type: .text, text: "plain"), parsed: nil)

        XCTAssertFalse(seed.formatted)
        XCTAssertEqual(seed.text.string, "plain")
    }

    /// Formatting nobody can parse is not formatting worth claiming to keep — and saying so is
    /// what stops the save writing plain RTF over it.
    func testUnreadableFormattingDoesNotClaimToBeKept() {
        let broken = ClipboardItem(type: .text, text: "hi",
                                   richData: Data([0x00, 0x01]), richType: "public.rtf")

        XCTAssertFalse(ItemEdit.editorSeed(for: broken, parsed: nil).formatted)
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
}
