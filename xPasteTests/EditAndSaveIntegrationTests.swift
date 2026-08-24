import XCTest
import AppKit
@testable import xPaste

/// Both new features driven end to end against a real store on a real directory, with the kind of
/// items that actually land in a clipboard.
///
/// The unit tests check each rule alone. These check the seams — chiefly that an item which has
/// been edited saves its *new* content, which is where six id-keyed caches get a chance to serve
/// yesterday's text.
final class EditAndSaveIntegrationTests: XCTestCase {

    private var directory: URL!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditAndSave-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ClipboardStore(maxItems: 50, storageDir: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        store = nil
    }

    // MARK: - Injecting realistic items

    private static let php = """
    <?php
    namespace App\\Support;

    function slugify(string $title): string {
        return strtolower(trim($title));
    }
    """

    private static let python = """
    from dataclasses import dataclass

    @dataclass
    class Order:
        total: float

    def total(orders):
        return sum(o.total for o in orders)
    """

    private static let json = #"{"name":"xPaste","version":"1.2.1","tags":["mac","clipboard"]}"#

    private static let prose = """
    Remember to ask about the invoice, and send the revised figures before Friday.
    """

    /// Real encoded bytes, not a handful of magic-byte constants — the point of a save is that what
    /// lands on disk opens.
    private static func imageBytes(opaque: Bool) -> Data {
        let size = NSSize(width: 24, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        (opaque ? NSColor.systemBlue : NSColor.systemBlue.withAlphaComponent(0.4)).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        // The app's own encoder, so these are exactly the bytes a real capture would store.
        return image.compressedData(maxBytes: 1_000_000)!
    }

    private static func richItem() -> ClipboardItem {
        let styled = NSMutableAttributedString(string: "release notes")
        styled.addAttribute(.backgroundColor, value: NSColor.yellow,
                            range: NSRange(location: 0, length: 7))
        return ClipboardItem(type: .text, text: "release notes",
                             richData: ItemEdit.rtf(from: styled),
                             richType: ItemEdit.richType)
    }

    @discardableResult
    private func inject(_ item: ClipboardItem) -> ClipboardItem {
        store.add(item)
        return store.items[0]
    }

    private func saved(_ item: ClipboardItem, imageBytes: Data? = nil) throws -> URL {
        let suggestion = SaveFormat.suggest(for: item, imageBytes: imageBytes)
        let target = directory.appendingPathComponent(suggestion.fileName)
        try ItemFileWriter.write(suggestion, to: target)
        return target
    }

    /// The item as the store holds it now, which is what the save path reads.
    private func reread(_ id: UUID) throws -> ClipboardItem {
        try XCTUnwrap(store.items.first { $0.id == id })
    }

    // MARK: - Saving what was injected

    func testASpreadOfRealItemsEachSaveUnderTheRightExtension() throws {
        let cases: [(ClipboardItem, String)] = [
            (ClipboardItem(type: .text, text: Self.php), "php"),
            (ClipboardItem(type: .text, text: Self.python), "py"),
            (ClipboardItem(type: .text, text: Self.json), "json"),
            (ClipboardItem(type: .text, text: Self.prose), "txt"),
            (ClipboardItem(type: .url, text: "https://example.com/a"), "html"),
        ]

        for (item, expected) in cases {
            let stored = inject(item)
            XCTAssertEqual(SaveFormat.suggest(for: stored).ext, expected,
                           "wrong extension for \(String((item.text ?? "").prefix(20)))")
        }
    }

    func testTextItemsLandOnDiskByteForByte() throws {
        let item = inject(ClipboardItem(type: .text, text: Self.php))

        let file = try saved(item)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), Self.php)
        XCTAssertEqual(file.pathExtension, "php")
    }

    /// The one the stored filename lies about: `ClipboardStore` names every image `.jpg` on disk,
    /// while `compressedData` writes PNG for anything using its alpha channel.
    func testATransparentImageSavesAsPNGAndAnOpaqueOneAsJPEG() throws {
        let transparent = Self.imageBytes(opaque: false)
        let opaque = Self.imageBytes(opaque: true)

        let pngItem = inject(ClipboardItem(type: .image, imageData: transparent))
        let jpgItem = inject(ClipboardItem(type: .image, imageData: opaque))

        XCTAssertEqual(SaveFormat.suggest(for: pngItem, imageBytes: transparent).ext, "png")
        XCTAssertEqual(SaveFormat.suggest(for: jpgItem, imageBytes: opaque).ext, "jpg")
    }

    func testASavedImageIsStillAnImageAndStillTheSameBytes() throws {
        let bytes = Self.imageBytes(opaque: true)
        let item = inject(ClipboardItem(type: .image, imageData: bytes))

        let file = try saved(item, imageBytes: bytes)

        XCTAssertEqual(try Data(contentsOf: file), bytes, "the bytes were re-encoded on the way out")
        XCTAssertNotNil(NSImage(contentsOf: file))
    }

    // MARK: - Editing, then saving: the seam

    /// The one that would break silently. Six caches key on the item's id, and the id does not
    /// change when the text does.
    func testAnItemThatWasEditedSavesTheNewContentNotTheOld() throws {
        let item = inject(ClipboardItem(type: .text, text: Self.prose))
        // Draw the card's caches first, exactly as scrolling past the card would.
        _ = SaveFormat.suggest(for: item)
        _ = RichTextRenderer.cachedParse(item)

        store.updateContent(id: item.id, text: Self.php, richData: nil, richType: nil)

        let file = try saved(try reread(item.id))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), Self.php)
        XCTAssertEqual(file.pathExtension, "php", "the extension was guessed from the old text")
    }

    func testEditingProseIntoALinkMakesItSaveAsThePage() throws {
        let item = inject(ClipboardItem(type: .text, text: Self.prose))

        store.updateContent(id: item.id, text: "https://example.com/moved",
                            richData: nil, richType: nil)

        let edited = try reread(item.id)
        XCTAssertEqual(edited.type, .url)
        let suggestion = SaveFormat.suggest(for: edited)
        XCTAssertEqual(suggestion.ext, "html")
        XCTAssertEqual(suggestion.payload,
                       .remoteHTML(URL(string: "https://example.com/moved")!))
    }

    func testEditingALinkBackIntoProseStopsItSavingAsAPage() throws {
        let item = inject(ClipboardItem(type: .url, text: "https://example.com"))

        store.updateContent(id: item.id, text: Self.prose, richData: nil, richType: nil)

        XCTAssertEqual(try reread(item.id).type, .text)
        XCTAssertEqual(try saved(try reread(item.id)).pathExtension, "txt")
    }

    // MARK: - Editing and the caches

    /// `RichTextRenderer` caches the parse under the item's id, positive and negative alike. An
    /// edit has to reach it, or the card draws the formatting the text no longer has.
    func testTheParsedFormattingIsDroppedWhenTheItemIsEdited() throws {
        let item = inject(Self.richItem())
        XCTAssertNotNil(RichTextRenderer.cachedParse(item), "nothing was cached to invalidate")

        store.updateContent(id: item.id, text: "plain now", richData: nil, richType: nil)

        XCTAssertNil(RichTextRenderer.cachedParse(try reread(item.id)),
                     "the card would still be drawing the old formatting")
    }

    func testEditingKeepsFormattingWhenTheEditorHandsSomeBack() throws {
        let item = inject(Self.richItem())
        let edited = NSMutableAttributedString(string: "release notes v2")
        edited.addAttribute(.backgroundColor, value: NSColor.yellow,
                            range: NSRange(location: 0, length: 7))

        store.updateContent(id: item.id, text: edited.string,
                            richData: ItemEdit.rtf(from: edited), richType: ItemEdit.richType)

        let stored = try reread(item.id)
        let parsed = try XCTUnwrap(RichTextRenderer.cachedParse(stored))
        XCTAssertEqual(parsed.text.string, "release notes v2")
        XCTAssertNotNil(parsed.text.attribute(.backgroundColor, at: 0, effectiveRange: nil),
                        "the highlight did not survive the round trip")
    }

    /// Every edit has to move the number the card's `.task` is keyed on, or the card never rebuilds
    /// anything it derived from the previous text.
    func testEveryEditMovesTheRevisionOn() throws {
        let item = inject(ClipboardItem(type: .text, text: "one"))

        store.updateContent(id: item.id, text: "two", richData: nil, richType: nil)
        store.updateContent(id: item.id, text: "three", richData: nil, richType: nil)

        XCTAssertEqual(try reread(item.id).contentRevision, 2)
    }

    // MARK: - Editing and the rest of the item

    func testEditingLeavesTheItemWhereItIsInTheHistory() throws {
        let first = inject(ClipboardItem(type: .text, text: "older"))
        inject(ClipboardItem(type: .text, text: "newer"))

        store.updateContent(id: first.id, text: "older, corrected", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.text, "newer", "the edit reordered the history")
        XCTAssertEqual(store.items.last?.text, "older, corrected")
    }

    func testEditingKeepsTheNameTheUserGaveTheItem() throws {
        let item = inject(ClipboardItem(type: .text, text: "curl -X POST", label: "deploy"))

        store.updateContent(id: item.id, text: "curl -X PUT", richData: nil, richType: nil)

        let edited = try reread(item.id)
        XCTAssertEqual(edited.label, "deploy")
        XCTAssertEqual(SaveFormat.suggest(for: edited).baseName, "deploy",
                       "the file should still be named after the item")
    }

    func testAnEditedItemStillPastesTheNewContent() throws {
        let item = inject(ClipboardItem(type: .text, text: "before"))
        store.updateContent(id: item.id, text: "after", richData: nil, richType: nil)

        let board = NSPasteboard(name: .init("xPasteTests-\(UUID().uuidString)"))
        try reread(item.id).write(to: board)

        XCTAssertEqual(board.string(forType: .string), "after")
    }

    /// Deleting has its own gesture and its own confirmation. An empty save must not become a
    /// second, silent way to lose an item.
    func testAnEmptyEditCannotDeleteAnItemByAccident() throws {
        let item = inject(ClipboardItem(type: .text, text: "still here"))

        store.updateContent(id: item.id, text: "", richData: nil, richType: nil)
        store.updateContent(id: item.id, text: "\n\t  ", richData: nil, richType: nil)

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(try reread(item.id).text, "still here")
    }

    func testEditsAndTheirRevisionsSurviveARestart() throws {
        let item = inject(ClipboardItem(type: .text, text: Self.prose))
        store.updateContent(id: item.id, text: Self.python, richData: nil, richType: nil)

        let written = expectation(description: "background save")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { written.fulfill() }
        wait(for: [written], timeout: 2)

        let reopened = ClipboardStore(maxItems: 50, storageDir: directory)
        let restored = try XCTUnwrap(reopened.items.first { $0.id == item.id })
        XCTAssertEqual(restored.text, Self.python)
        XCTAssertEqual(restored.contentRevision, 1)
        XCTAssertEqual(SaveFormat.suggest(for: restored).ext, "py")
    }

    // MARK: - The session's raw/formatted round trip, end to end

    /// An edit made by typing markup has to reach storage as formatting, not as the markup itself.
    func testAnEditMadeThroughRawModeReachesStorageFormatted() throws {
        let item = inject(ClipboardItem(type: .text, text: "hello"))
        let draft = try XCTUnwrap(RichTextHTML.attributed(from: "<p><b>hello</b> world</p>"))
        XCTAssertTrue(ItemEdit.carriesFormatting(draft))

        store.updateContent(id: item.id, text: draft.string,
                            richData: ItemEdit.rtf(from: draft), richType: ItemEdit.richType)

        let stored = try reread(item.id)
        XCTAssertEqual(stored.text, "hello world")
        XCTAssertEqual(stored.richType, ItemEdit.richType)
        let parsed = try XCTUnwrap(RichTextRenderer.cachedParse(stored))
        let font = parsed.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font ?? ItemEdit.plainFont)
            .contains(.boldFontMask), "the bold word did not survive the round trip")
    }

    /// The other direction, and the one that would go unnoticed: markup typed into raw mode that
    /// styles nothing must not turn a plain item into an RTF-storing one.
    func testMarkupThatStylesNothingLeavesAPlainItemPlain() throws {
        let item = inject(ClipboardItem(type: .text, text: "hello"))
        let draft = try XCTUnwrap(RichTextHTML.attributed(from: "<p>hello there</p>"))
        XCTAssertFalse(ItemEdit.carriesFormatting(draft))

        store.updateContent(id: item.id, text: draft.string, richData: nil, richType: nil)

        let stored = try reread(item.id)
        XCTAssertEqual(stored.text, "hello there")
        XCTAssertNil(stored.richType)
    }
}
