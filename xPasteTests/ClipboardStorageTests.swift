import XCTest
import AppKit
import SwiftUI
@testable import xPaste

/// What the payload keeps, what it refuses, and what it costs.
final class PasteboardPayloadTests: XCTestCase {

    private var board: NSPasteboard!

    override func setUp() {
        super.setUp()
        board = NSPasteboard(name: .init("PayloadTests-" + UUID().uuidString))
        board.clearContents()
    }

    override func tearDown() {
        board.releaseGlobally()
        super.tearDown()
    }

    private func put(_ pairs: [(String, Data)]) {
        let item = NSPasteboardItem()
        for (type, data) in pairs { item.setData(data, forType: .init(type)) }
        board.clearContents()
        board.writeObjects([item])
    }

    func testEveryRepresentationTheSourceOfferedIsKept() throws {
        put([("public.rtf", Data("{\\rtf1 hi}".utf8)),
             ("public.utf8-plain-text", Data("hi".utf8)),
             ("com.acme.private", Data([0x1, 0x2, 0x3]))])

        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board))

        XCTAssertEqual(payload.data(forType: "com.acme.private"), Data([0x1, 0x2, 0x3]),
                       "an app-specific type is exactly what the old one-rich-type capture lost")
        XCTAssertEqual(payload.data(forType: "public.rtf"), Data("{\\rtf1 hi}".utf8))
        XCTAssertEqual(payload.data(forType: "public.utf8-plain-text"), Data("hi".utf8))
    }

    /// The source's order is its preference order, and a receiving app honours it.
    ///
    /// A subsequence rather than an equality: AppKit derives extra flavours from what it is given —
    /// write `public.utf8-plain-text` and the board also reports the UTF-16 one — so the replayed
    /// list is longer than the stored one by design. What has to hold is that the stored types come
    /// back in the order they went in.
    func testTypeOrderSurvivesCaptureAndReplay() throws {
        put([("public.rtf", Data("rtf".utf8)), ("public.utf8-plain-text", Data("plain".utf8))])
        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board))

        let replayed = NSPasteboard(name: .init("Replay-" + UUID().uuidString))
        defer { replayed.releaseGlobally() }
        replayed.clearContents()
        payload.write(to: replayed)

        let got = try XCTUnwrap(replayed.pasteboardItems?.first?.types.map(\.rawValue))
        XCTAssertEqual(got.filter(payload.items[0].types.contains), payload.items[0].types)
    }

    /// `pasteboardItems` reports the canonical types and leaves AppKit's legacy aliases out —
    /// `pb.types` says six for a rich-text copy where this says three. Capture reads the item, so
    /// the aliases are never stored, and a replay puts them back because AppKit derives them.
    func testTheLegacyAliasesAreNeitherStoredNorLost() throws {
        let rich = NSAttributedString(string: "hi", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        board.clearContents()
        board.writeObjects([rich])

        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board))

        XCTAssertNil(payload.data(forType: "NeXT Rich Text Format v1.0 pasteboard type"),
                     "an alias of public.rtf was stored as a second copy of the same bytes")
        XCTAssertNotNil(payload.data(forType: "public.rtf"))

        let replayed = NSPasteboard(name: .init("Alias-" + UUID().uuidString))
        defer { replayed.releaseGlobally() }
        replayed.clearContents()
        payload.write(to: replayed)
        XCTAssertNotNil(replayed.data(forType: .init("NeXT Rich Text Format v1.0 pasteboard type")),
                        "AppKit did not derive the alias back")
    }

    /// An app offering the same bytes under a public type and a private one of its own. Binary
    /// plists do not unique `Data`, so without an explicit blob table this is stored twice.
    ///
    /// Deliberately not spelled with `public.rtf` and its NeXT alias: those unify into one type the
    /// moment they are written to a board, so the pair cannot be built — see
    /// `testTheLegacyAliasesAreNeitherStoredNorLost`.
    func testIdenticalBytesUnderTwoTypesAreStoredOnce() throws {
        let blob = Data(repeating: 0xAB, count: 4096)
        put([("com.acme.canonical", blob), ("com.acme.mirror", blob)])

        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board))
        let encoded = try payload.encoded()

        XCTAssertEqual(payload.byteCount, 4096, "the shared blob counted twice")
        XCTAssertLessThan(encoded.count, 4096 + 1024,
                          "the encoded form carries a second copy of the same 4 KB")
        let decoded = try XCTUnwrap(PasteboardPayload(decoding: encoded))
        XCTAssertEqual(decoded.data(forType: "com.acme.canonical"), blob)
        XCTAssertEqual(decoded.data(forType: "com.acme.mirror"), blob)
    }

    func testRoundTripThroughTheStoredFormIsExact() throws {
        put([("public.utf8-plain-text", Data("xin chào".utf8)),
             ("com.acme.binary", Data((0..<255).map(UInt8.init)))])
        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board))

        let decoded = try XCTUnwrap(PasteboardPayload(decoding: try payload.encoded()))

        XCTAssertEqual(decoded, payload)
    }

    func testBytesThatAreNotAPayloadDecodeToNilRatherThanThrowing() {
        XCTAssertNil(PasteboardPayload(decoding: Data("not a plist".utf8)))
        XCTAssertNil(PasteboardPayload(decoding: Data()))
    }

    /// An icon for a file the payload already names by path, measured at 251 KB for one folder
    /// copied out of Finder — larger than everything else in that item together.
    func testTheIconOfACopiedFileIsNotStored() throws {
        put([("public.file-url", Data("file:///tmp/x".utf8)),
             ("com.apple.icns", Data(repeating: 0x9, count: 200_000))])

        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board))

        XCTAssertNil(payload.data(forType: "com.apple.icns"))
        XCTAssertNotNil(payload.data(forType: "public.file-url"))
    }

    /// A promise names bytes the source app produces on demand, and the promise dies with the copy.
    func testPromisedFileTypesAreNotStored() {
        XCTAssertFalse(PasteboardPayload.isStorable("com.apple.pasteboard.promised-file-url"))
        XCTAssertFalse(PasteboardPayload.isStorable("com.apple.pasteboard.promised-file-content-type"))
        XCTAssertTrue(PasteboardPayload.isStorable("public.rtf"))
    }

    func testARepresentationOverTheCapIsLeftOutAndTheRestIsKept() throws {
        let limits = PasteboardPayload.Limits(perRepresentation: 1000, total: 1_000_000)
        put([("public.utf8-plain-text", Data("small".utf8)),
             ("com.acme.huge", Data(repeating: 0x1, count: 5000))])

        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board, limits: limits))

        XCTAssertNil(payload.data(forType: "com.acme.huge"))
        XCTAssertEqual(payload.data(forType: "public.utf8-plain-text"), Data("small".utf8))
    }

    /// A type sharing bytes with one the budget has already refused must be refused too — it was
    /// stored for free, because the refused blob had been interned before the budget was consulted.
    func testATypeSharingBytesWithARefusedOneIsNotStoredForFree() throws {
        let big = Data(repeating: 0x3, count: 900)
        let limits = PasteboardPayload.Limits(perRepresentation: 10_000, total: 500)
        put([("com.acme.first", big), ("com.acme.second", big),
             ("public.utf8-plain-text", Data("small".utf8))])

        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board, limits: limits))

        XCTAssertNil(payload.data(forType: "com.acme.first"))
        XCTAssertNil(payload.data(forType: "com.acme.second"),
                     "the second type rode in on bytes the budget had already turned down")
        XCTAssertEqual(payload.data(forType: "public.utf8-plain-text"), Data("small".utf8))
        XCTAssertLessThanOrEqual(payload.byteCount, limits.total)
    }

    /// And when nothing at all fits, there is no payload rather than an empty one.
    func testAnItemWhoseEveryRepresentationIsOverBudgetHasNoPayload() {
        let limits = PasteboardPayload.Limits(perRepresentation: 10_000, total: 100)
        put([("com.acme.only", Data(repeating: 0x3, count: 900))])

        XCTAssertNil(PasteboardPayload.capture(from: board, limits: limits))
    }

    func testTheTotalCapStopsAtTheSourcesOwnLowestRankedTypes() throws {
        let limits = PasteboardPayload.Limits(perRepresentation: 10_000, total: 1200)
        put([("public.rtf", Data(repeating: 0x1, count: 1000)),
             ("com.acme.extra", Data(repeating: 0x2, count: 1000))])

        let payload = try XCTUnwrap(PasteboardPayload.capture(from: board, limits: limits))

        XCTAssertNotNil(payload.data(forType: "public.rtf"), "the source ranked this first")
        XCTAssertNil(payload.data(forType: "com.acme.extra"))
    }
}

/// The hot/cold split, and the paths where reading only the hot half would lose the user's text.
final class ClipboardStorageSplitTests: XCTestCase {

    private var directory: URL!
    private var store: ClipboardStore!

    /// Comfortably past `ItemEntity.previewCharLimit`, and not a repeated character, so a prefix
    /// cannot pass for the whole by accident.
    private let longText = (0..<9000).map { String(UnicodeScalar(97 + $0 % 26)!) }.joined()

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Split-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ClipboardStore(maxItems: 50, storageDir: directory)
    }

    override func tearDownWithError() throws {
        store?.flushPendingWrites()
        store = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func addLongTextItem() {
        var item = ClipboardItem(type: .text, text: longText)
        item.payload = .plainText(longText)
        store.add(item)
    }

    private func reopened() -> ClipboardStore {
        store.flushPendingWrites()
        return ClipboardStore(maxItems: 50, storageDir: directory)
    }

    func testTheHotHalfIsCappedSoTheHistoryDoesNotHoldWholeDocuments() throws {
        addLongTextItem()

        let restored = try XCTUnwrap(reopened().items.first)

        XCTAssertEqual(restored.text?.count, ItemEntity.previewCharLimit)
        XCTAssertEqual(restored.textLength, longText.count)
        XCTAssertTrue(restored.isTextTruncated)
    }

    /// The other half of that trade: everything that pastes, saves, drags or edits has to get all
    /// of it back. This is the failure the cap could cause, so it is asserted directly.
    func testHydrationGivesTheWholeTextBack() throws {
        addLongTextItem()
        let reopenedStore = reopened()
        let restored = try XCTUnwrap(reopenedStore.items.first)

        XCTAssertEqual(reopenedStore.fullText(for: restored), longText)
        XCTAssertEqual(reopenedStore.hydrated(restored).text, longText)
    }

    /// The checksum is written from the full content and read back from the store, rather than
    /// derived again from the prefix — otherwise dedup silently stops recognising long texts the
    /// moment the app restarts.
    func testALongTextIsStillRecognisedAsADuplicateAfterARelaunch() throws {
        addLongTextItem()
        let reopenedStore = reopened()
        XCTAssertEqual(reopenedStore.items.count, 1)

        var again = ClipboardItem(type: .text, text: longText)
        again.payload = .plainText(longText)
        reopenedStore.add(again)

        XCTAssertEqual(reopenedStore.items.count, 1, "the same long text was stored twice")
    }

    func testPastingReplaysEveryStoredRepresentation() throws {
        var item = ClipboardItem(type: .text, text: "hi")
        item.payload = PasteboardPayload(items: [.init(
            types: ["public.rtf", "com.acme.private", "public.utf8-plain-text"],
            dataByType: ["public.rtf": Data("{\\rtf1 hi}".utf8),
                         "com.acme.private": Data([0x7]),
                         "public.utf8-plain-text": Data("hi".utf8)])])
        store.add(item)
        store.flushPendingWrites()

        let payload = try XCTUnwrap(store.payload(for: item.id))
        let board = NSPasteboard(name: .init("Replay-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        payload.write(to: board)

        XCTAssertEqual(board.data(forType: .init("com.acme.private")), Data([0x7]))
        XCTAssertEqual(board.data(forType: .init("public.rtf")), Data("{\\rtf1 hi}".utf8))
    }

    /// An edit rewrites the text the payload replays. Without it the card shows one thing and
    /// pasting produces another.
    func testEditingRewritesWhatAPasteWillProduce() throws {
        var item = ClipboardItem(type: .text, text: "before")
        item.payload = PasteboardPayload(items: [.init(
            types: ["public.utf8-plain-text", "com.acme.private"],
            dataByType: ["public.utf8-plain-text": Data("before".utf8),
                         "com.acme.private": Data([0x5])])])
        store.add(item)

        store.updateContent(id: item.id, text: "after", richData: nil, richType: nil)
        store.flushPendingWrites()

        let payload = try XCTUnwrap(store.payload(for: item.id))
        XCTAssertEqual(payload.string, "after")
        XCTAssertEqual(payload.data(forType: "com.acme.private"), Data([0x5]),
                       "an edit dropped a representation it had no business touching")
    }

    /// The edited item must not still be filed under what it used to say.
    func testAnEditedItemIsNotDeduplicatedAwayByItsOwnOldText() {
        let item = ClipboardItem(type: .text, text: "before")
        store.add(item)
        store.updateContent(id: item.id, text: "after", richData: nil, richType: nil)

        store.add(ClipboardItem(type: .text, text: "before"))

        XCTAssertEqual(store.items.count, 2)
        XCTAssertTrue(store.items.contains { $0.text == "after" })
    }

    /// The claim the whole schema rests on: drawing the history must not read the payloads.
    func testLoadingTheHistoryDoesNotBringThePayloadsWithIt() throws {
        for i in 0..<20 {
            var item = ClipboardItem(type: .text, text: "item \(i)")
            item.payload = PasteboardPayload(items: [.init(
                types: ["public.utf8-plain-text", "com.acme.bulk"],
                dataByType: ["public.utf8-plain-text": Data("item \(i)".utf8),
                             "com.acme.bulk": Data(repeating: UInt8(i), count: 40_000)])])
            store.add(item)
        }

        let restored = reopened().items

        XCTAssertEqual(restored.count, 20)
        XCTAssertTrue(restored.allSatisfy { $0.payload == nil && $0.richData == nil },
                      "the cold half came back with the hot half")
    }

    /// Large representations belong beside the database, not inside it — the same thing Paste gets
    /// from `allowsExternalBinaryDataStorage`, and the reason the attribute lives in an entity of
    /// its own.
    func testALargePayloadIsStoredOutsideTheDatabaseFile() throws {
        var item = ClipboardItem(type: .text, text: "big")
        item.payload = PasteboardPayload(items: [.init(
            types: ["com.acme.bulk"],
            dataByType: ["com.acme.bulk": Data(repeating: 0x5, count: 2_000_000)])])
        store.add(item)
        store.flushPendingWrites()

        let external = directory
            .appendingPathComponent(".ClipboardHistory_SUPPORT")
            .appendingPathComponent("_EXTERNAL_DATA")
        let files = try FileManager.default.contentsOfDirectory(atPath: external.path)

        XCTAssertEqual(files.count, 1, "the 2 MB blob was written into the database file itself")
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: external.appendingPathComponent(files[0]).path)[.size] as? Int)
        XCTAssertGreaterThan(size, 1_900_000)
        // And it is still readable through the ordinary path.
        XCTAssertEqual(store.payload(for: item.id)?.data(forType: "com.acme.bulk")?.count, 2_000_000)
    }

    /// Two images that carry no bytes and no hash are still two images. They shared a dedup key
    /// once, which made copying either one delete the other.
    func testItemsWithNoIdentifyingContentDoNotDeduplicateOntoEachOther() {
        store.add(ClipboardItem(type: .image, imageData: nil))
        store.add(ClipboardItem(type: .image, imageData: nil))
        store.add(ClipboardItem(type: .file, fileURLs: []))
        store.add(ClipboardItem(type: .file, fileURLs: []))

        XCTAssertEqual(store.items.count, 4)
    }

    func testDeletingAnItemTakesItsPayloadWithIt() throws {
        var item = ClipboardItem(type: .text, text: "gone")
        item.payload = .plainText("gone")
        store.add(item)
        store.flushPendingWrites()
        XCTAssertNotNil(store.payload(for: item.id))

        store.delete(item)
        store.flushPendingWrites()

        XCTAssertNil(store.payload(for: item.id))
        let database = try XCTUnwrap(ClipboardDatabase(storageDir: directory))
        XCTAssertEqual(database.pruneOrphanedPayloads(), 0, "the payload outlived its item")
    }
}

/// Reading a history written before the database existed.
final class LegacyJSONImportTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legacy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("items"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func writeLegacyItem(_ json: String, id: UUID) throws {
        try Data(json.utf8).write(to: directory
            .appendingPathComponent("items")
            .appendingPathComponent(id.uuidString + ".json"))
    }

    func testItemsWrittenAsJSONAreImportedAndTheOldFilesGoAway() throws {
        let id = UUID()
        try writeLegacyItem("""
        {"id":"\(id.uuidString)","type":"text","text":"còn nợ","isPinned":true,
         "timestamp":809315195.129473,"sourceAppBundleID":"com.apple.Terminal"}
        """, id: id)

        let store = ClipboardStore(maxItems: 50, storageDir: directory)

        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.text, "còn nợ")
        XCTAssertTrue(item.isPinned)
        XCTAssertEqual(item.sourceAppBundleID, "com.apple.Terminal")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("items").path),
            "the old files were left behind and will be imported again next launch")
    }

    /// The old format kept one formatted representation, so that is exactly what the imported
    /// payload has — and a paste of an imported item still carries its styling.
    func testAnImportedItemKeepsTheFormattingTheOldFormatHad() throws {
        let id = UUID()
        let rtf = Data("{\\rtf1 hi}".utf8).base64EncodedString()
        try writeLegacyItem("""
        {"id":"\(id.uuidString)","type":"text","text":"hi","isPinned":false,
         "timestamp":809315195.0,"richData":"\(rtf)","richType":"public.rtf"}
        """, id: id)

        let store = ClipboardStore(maxItems: 50, storageDir: directory)
        let item = try XCTUnwrap(store.items.first)

        XCTAssertTrue(item.carriesRichText)
        XCTAssertEqual(store.richBytes(for: item), Data("{\\rtf1 hi}".utf8))
    }

    /// A file that does not decode must not be able to stop the rest of the history from loading.
    func testOneUnreadableFileDoesNotStopTheImport() throws {
        let good = UUID()
        try writeLegacyItem("""
        {"id":"\(good.uuidString)","type":"text","text":"kept","isPinned":false,
         "timestamp":809315195.0}
        """, id: good)
        try writeLegacyItem("{ this is not json", id: UUID())

        let store = ClipboardStore(maxItems: 50, storageDir: directory)

        XCTAssertEqual(store.items.map(\.text), ["kept"])
    }
}

/// Which copy of a picture each path gets. Only the card draws the thumbnail; everything that
/// hands the picture to somebody else gets what the source app actually put on the clipboard.
final class ImageFidelityTests: XCTestCase {

    private var directory: URL!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fidelity-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ClipboardStore(maxItems: 50, storageDir: directory)
    }

    override func tearDownWithError() throws {
        store?.flushPendingWrites()
        store = nil
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// A picture with enough detail that a JPEG re-encode cannot come out identical to the PNG.
    private func picture(_ side: Int) throws -> (png: Data, jpeg: Data) {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        for i in stride(from: 0, to: side, by: 3) {
            NSColor(calibratedHue: CGFloat(i % 360) / 360, saturation: 0.9,
                    brightness: 0.9, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: i, y: 0, width: 3, height: side)).fill()
        }
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return (try XCTUnwrap(rep.representation(using: .png, properties: [:])),
                try XCTUnwrap(rep.representation(using: .jpeg,
                                                 properties: [.compressionFactor: 0.3])))
    }

    /// Adds an image item the way capture does: the re-encode as the card's thumbnail, the
    /// original in the payload.
    private func addImage(original: Data, thumbnail: Data) -> ClipboardItem {
        var item = ClipboardItem(type: .image, imageData: thumbnail)
        item.payload = PasteboardPayload(items: [.init(
            types: ["public.png"], dataByType: ["public.png": original])])
        store.add(item)
        store.flushPendingWrites()
        return item
    }

    func testTheCardStillDrawsTheThumbnail() throws {
        let (png, jpeg) = try picture(120)
        let item = addImage(original: png, thumbnail: jpeg)

        XCTAssertEqual(store.imageBytes(for: item.id), jpeg,
                       "the card path started reading the original")
    }

    func testEverythingElseGetsTheOriginal() throws {
        let (png, jpeg) = try picture(120)
        let item = addImage(original: png, thumbnail: jpeg)
        let restored = try XCTUnwrap(store.items.first)

        XCTAssertEqual(store.originalImageBytes(for: restored), png)
        XCTAssertNotEqual(store.originalImageBytes(for: restored), jpeg)
    }

    /// Pasting replays the payload, so it carries the original without going through the accessor
    /// at all — asserted here because it is the path a user notices first.
    func testPastingPutsTheOriginalOnThePasteboard() throws {
        let (png, jpeg) = try picture(120)
        let item = addImage(original: png, thumbnail: jpeg)

        let board = NSPasteboard(name: .init("Fidelity-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let payload = try XCTUnwrap(store.payload(for: item.id))
        board.clearContents()
        payload.write(to: board)

        XCTAssertEqual(board.data(forType: .init("public.png")), png)
    }

    /// An item imported from the JSON history never had an original, so for those there is only
    /// one picture and every path has to get it rather than nothing.
    func testAnItemWithNoOriginalFallsBackToTheOnlyCopyItHas() throws {
        let (_, jpeg) = try picture(80)
        var item = ClipboardItem(type: .image, imageData: jpeg)
        item.payload = nil
        store.add(item)
        store.flushPendingWrites()
        let restored = try XCTUnwrap(store.items.first)

        XCTAssertEqual(store.originalImageBytes(for: restored), jpeg)
    }

    func testTheOriginalIsNotPutIntoTheThumbnailCache() async throws {
        let (png, jpeg) = try picture(120)
        let item = addImage(original: png, thumbnail: jpeg)
        let restored = try XCTUnwrap(store.items.first)

        _ = await store.loadOriginalImage(for: restored)

        // The cache is bounded for thumbnails; one original can be larger than the whole budget.
        XCTAssertEqual(store.imageBytes(for: item.id), jpeg)
    }

    /// Lossless first, and never empty just because the source used a format this list does not
    /// name.
    func testTheLosslessRepresentationIsPreferred() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x1])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x1])
        let both = PasteboardPayload(items: [.init(
            types: ["public.jpeg", "public.png"],
            dataByType: ["public.jpeg": jpeg, "public.png": png])])
        XCTAssertEqual(both.imageRepresentation?.data, png)

        let heicOnly = PasteboardPayload(items: [.init(
            types: ["public.heic"], dataByType: ["public.heic": Data([0x1, 0x2])])])
        XCTAssertEqual(heicOnly.imageRepresentation?.type, "public.heic",
                       "a format the preference list does not name came back as no picture at all")

        let noPicture = PasteboardPayload.plainText("hi")
        XCTAssertNil(noPicture.imageRepresentation)
    }
}

/// How a picture is fed to Vision. See `OCRService.tileSide` for what these numbers came from.
final class OCRTilingTests: XCTestCase {

    func testASmallPictureIsReadInOnePass() {
        XCTAssertEqual(OCRService.tiles(width: 800, height: 600).count, 1)
    }

    func testALargePictureIsCutUp() {
        XCTAssertEqual(OCRService.tiles(width: 3024, height: 1890).count, 6,
                       "3 columns by 2 rows at a 1200px tile")
    }

    /// Every pixel has to be inside some tile, or text lands in a gap and is never read.
    func testTheTilesCoverTheWholePicture() {
        let tiles = OCRService.tiles(width: 3024, height: 1890)

        for x in stride(from: 0, to: 3024, by: 97) {
            for y in stride(from: 0, to: 1890, by: 97) {
                let point = CGPoint(x: x, y: y)
                XCTAssertTrue(tiles.contains { $0.contains(point) },
                              "nothing reads the pixel at \(x),\(y)")
            }
        }
    }

    /// Neighbours reach into each other, so a line of text sitting across a cut is whole in at
    /// least one of them.
    func testNeighbouringTilesOverlap() throws {
        let tiles = OCRService.tiles(width: 3024, height: 1890)
        let first = try XCTUnwrap(tiles.first)
        let second = try XCTUnwrap(tiles.dropFirst().first)
        XCTAssertTrue(first.intersects(second))
        XCTAssertGreaterThan(first.intersection(second).width, 50)
    }

    /// The picture nobody expects: a full-page capture. Read in one pass rather than in hundreds
    /// of tiles — the same answer as before tiling existed, which is the right thing to degrade to.
    func testAnEnormousPictureFallsBackToOnePass() {
        XCTAssertEqual(OCRService.tiles(width: 4000, height: 40_000).count, 1)
    }

    /// The whole point, end to end: text too small for Vision to find in the picture entire.
    func testSmallTextInATallPictureIsRecovered() async throws {
        let width = 3200, height = 2000
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(calibratedWhite: 0.93, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        ("Hoa don so HD-2026-08841" as NSString).draw(at: NSPoint(x: 40, y: 1900), withAttributes: attrs)
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let text = await OCRService.recognizeText(in: png)

        XCTAssertTrue(text.contains("HD-2026-08841"),
                      "small text went unread; got \"\(text)\"")
    }
}

/// Naming a picture from its bytes. See `SaveFormat.recognisedImageExtension`.
final class ImageFormatRecognitionTests: XCTestCase {

    private func header(_ bytes: [UInt8]) -> Data { Data(bytes + Array(repeating: 0, count: 24)) }

    func testTheFormatsPicturesActuallyArriveInAreRecognised() {
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: header([0x89, 0x50, 0x4E, 0x47])), "png")
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: header([0xFF, 0xD8, 0xFF])), "jpg")
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: header([0x47, 0x49, 0x46, 0x38])), "gif")
    }

    /// The one that mattered: `NSPasteboard` offers `public.tiff` and nothing else for an ordinary
    /// image copy, so an unrecognised TIFF meant a drag wrote no file and a save mislabelled one.
    func testTIFFIsRecognisedInBothByteOrders() {
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: header([0x49, 0x49, 0x2A, 0x00])), "tiff")
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: header([0x4D, 0x4D, 0x00, 0x2A])), "tiff")
    }

    func testHEICAndWebPAreRecognised() {
        let heic: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: header(heic)), "heic")
        let webp: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: header(webp)), "webp")
    }

    /// Still nil rather than a guess when the bytes say nothing — that is what lets a drag hand
    /// over the bitmap instead of writing a file under a name it cannot justify.
    func testBytesThatNameNothingAreStillRefused() {
        XCTAssertNil(SaveFormat.recognisedImageExtension(for: header([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(SaveFormat.recognisedImageExtension(for: Data()))
        // `ftyp` with a brand that is not a picture.
        let mp4: [UInt8] = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D]
        XCTAssertNil(SaveFormat.recognisedImageExtension(for: header(mp4)))
    }

    /// A real macOS image copy: TIFF, and a drag has to produce a file for it.
    func testARealImageCopyCanBeDraggedOutAsAFile() throws {
        let drawn = NSImage(size: NSSize(width: 6, height: 6))
        drawn.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 6, height: 6)).fill()
        drawn.unlockFocus()
        let tiff = try XCTUnwrap(drawn.tiffRepresentation)
        XCTAssertEqual(SaveFormat.recognisedImageExtension(for: tiff), "tiff",
                       "an ordinary image copy is TIFF and has to be nameable")

        let item = ClipboardItem(type: .image, imageData: tiff, label: "capture")
        defer { DragTempFile.clearLeftovers() }
        let url = try XCTUnwrap(DragTempFile.url(for: item),
                                "no file was written, so the drag would deliver the word Image")
        XCTAssertEqual(url.pathExtension, "tiff")
        XCTAssertEqual(try Data(contentsOf: url), tiff)
    }

    /// And when no file can be written, the drag carries the picture rather than its title.
    func testAnImageWithUnnameableBytesDragsAsAPictureNotAsText() throws {
        // A bitmap NSImage can read but `recognisedImageExtension` will not name.
        let drawn = NSImage(size: NSSize(width: 4, height: 4))
        drawn.lockFocus(); NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill(); drawn.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(drawn.tiffRepresentation)))
        let bmp = try XCTUnwrap(rep.representation(using: .bmp, properties: [:]))
        XCTAssertNil(SaveFormat.recognisedImageExtension(for: bmp), "premise: BMP is not nameable")

        let item = ClipboardItem(type: .image, imageData: bmp, label: "shape")
        let writer = CardDragSourceView.nativeWriter(for: item)

        XCTAssertTrue(writer is NSImage,
                      "the drag fell back to text; it would drop the word \"shape\" instead")
    }
}

/// The never-store patterns, on the one path that used to skip them.
final class OCRExclusionTests: XCTestCase {

    private let patterns = ["/sk-[A-Za-z0-9]{8,}/", "4111 1111"]

    func testTextMatchingANeverStorePatternIsNotKept() {
        XCTAssertEqual(OCRService.storable("token sk-ABCD1234EFGH here", patterns: patterns), "",
                       "a secret read out of a screenshot was written to the history")
        XCTAssertEqual(OCRService.storable("card 4111 1111 2222", patterns: patterns), "")
    }

    func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(OCRService.storable("Hoa don 12.500.000", patterns: patterns),
                       "Hoa don 12.500.000")
    }

    /// Empty, not nil: nil means "never scanned", which would put the picture back in the queue
    /// and have it read again on every launch.
    func testARefusedResultStillCountsAsScanned() {
        XCTAssertNotNil(OCRService.storable("sk-ABCD1234EFGH", patterns: patterns))
    }

    func testWithNoPatternsNothingIsFiltered() {
        XCTAssertEqual(OCRService.storable("sk-ABCD1234EFGH", patterns: []), "sk-ABCD1234EFGH")
    }
}

/// What the "Paste as…" menu is allowed to cost. See `TextTransform.probeLimit`.
final class TransformMenuCostTests: XCTestCase {

    private func prose(kilobytes: Int) -> String {
        let line = "Nguyen Van Long — hoa don 12.500.000 VND, ngay 25/08/2026\n"
        var text = ""
        while text.utf8.count < kilobytes * 1024 { text += line }
        return text
    }

    /// Deciding the menu used to run every transform over the whole item: 533ms for 4 MB.
    func testTheMenuIsBuiltFromABoundedSample() {
        let big = prose(kilobytes: 4096)
        let started = Date()
        _ = TextTransform.applicable(to: big, type: .text)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.1, "building the menu walked the whole item again")
    }

    /// And offers the same entries it did when it read everything.
    func testABoundedSampleOffersTheSameEntries() {
        let small = prose(kilobytes: 4)
        let big = prose(kilobytes: 512)
        XCTAssertEqual(TextTransform.applicable(to: small, type: .text),
                       TextTransform.applicable(to: big, type: .text))
    }

    /// The sample keeps both ends, so a change that only shows in the tail is still seen.
    func testTrailingWhitespaceIsStillNoticedInALongItem() {
        let text = prose(kilobytes: 512) + "     "
        XCTAssertTrue(TextTransform.applicable(to: text, type: .text).contains(.trimWhitespace))
    }

    /// Past the parse budget the shape decides, so a large document keeps its JSON entries.
    func testALargeJSONDocumentStillOffersItsEntries() throws {
        var object: [String: Any] = [:]
        for i in 0..<20_000 { object["key\(i)"] = ["a": i, "b": "value \(i)"] }
        let json = try XCTUnwrap(String(
            data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        XCTAssertGreaterThan(json.utf8.count, 256 * 1024, "premise: past the parse budget")

        XCTAssertTrue(TextTransform.applicable(to: json, type: .text).contains(.prettyJSON))
    }

    /// And a large piece of prose does not pick them up by accident.
    func testLongProseIsNotMistakenForJSON() {
        XCTAssertFalse(TextTransform.applicable(to: prose(kilobytes: 600), type: .text)
            .contains(.prettyJSON))
    }

    func testTheShapeCheckWantsBothEnds() {
        XCTAssertTrue(TextTransform.looksLikeJSON("  { \"a\": 1 }  "))
        XCTAssertTrue(TextTransform.looksLikeJSON("[1, 2, 3]"))
        XCTAssertFalse(TextTransform.looksLikeJSON("{ \"a\": 1"), "an unterminated object")
        XCTAssertFalse(TextTransform.looksLikeJSON("hello { }"))
        XCTAssertFalse(TextTransform.looksLikeJSON(""))
    }
}

/// The history cap — the one path in the app that deletes items the user did not ask to delete.
///
/// It had no coverage at all. Every store in the suite is built with a `maxItems` of 5, 10 or 50,
/// and `ClipboardStore.maxItems` clamps its argument up to `minHistoryCount` (500) before `trim()`
/// ever sees it — so no test had enough items to reach the cap, and the ones named for it passed
/// without it running. Getting there takes 501 items, which is what these do.
final class HistoryCapTests: XCTestCase {

    private var directory: URL!
    private let key = "maxHistoryCount"
    private var savedDefault: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedDefault = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(ClipboardStore.minHistoryCount, forKey: key)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cap-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let savedDefault { UserDefaults.standard.set(savedDefault, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func fill(_ store: ClipboardStore, count: Int, pinningFirst: Bool = false) -> [UUID] {
        var ids: [UUID] = []
        for i in 0..<count {
            var item = ClipboardItem(type: .text, text: "item \(i)",
                                     timestamp: Date().addingTimeInterval(Double(i)))
            item.payload = .plainText("item \(i)")
            if i == 0, pinningFirst { item.isPinned = true }
            store.add(item)
            ids.append(item.id)
        }
        return ids
    }

    func testTheCapIsEnforcedAndPinnedItemsDoNotCountTowardsIt() throws {
        let cap = ClipboardStore.minHistoryCount
        let store = ClipboardStore(maxItems: cap, storageDir: directory)
        let ids = fill(store, count: cap + 60, pinningFirst: true)

        XCTAssertEqual(store.items.filter { !$0.isPinned }.count, cap)
        XCTAssertTrue(store.items.contains { $0.id == ids[0] }, "the pinned item was trimmed")
        XCTAssertEqual(store.items.count, cap + 1, "a pinned item was counted against the cap")
    }

    /// What was trimmed has to be gone from the store too, or it comes back on the next launch.
    func testTrimmedItemsAreGoneFromTheDatabaseAsWell() throws {
        let cap = ClipboardStore.minHistoryCount
        let store = ClipboardStore(maxItems: cap, storageDir: directory)
        _ = fill(store, count: cap + 60)
        store.flushPendingWrites()

        let reopened = ClipboardStore(maxItems: cap, storageDir: directory)
        XCTAssertEqual(Set(store.items.map(\.id)), Set(reopened.items.map(\.id)))

        let database = try XCTUnwrap(ClipboardDatabase(storageDir: directory))
        XCTAssertEqual(database.pruneOrphanedPayloads(), 0,
                       "the trimmed items left their payloads behind")
    }

    /// Lowering the slider in Settings prunes immediately, oldest first.
    func testLoweringTheCapPrunesTheOldestFirst() throws {
        UserDefaults.standard.set(1000, forKey: key)
        let store = ClipboardStore(maxItems: 1000, storageDir: directory)
        _ = fill(store, count: 700)
        XCTAssertEqual(store.items.count, 700)

        UserDefaults.standard.set(ClipboardStore.minHistoryCount, forKey: key)
        store.enforceHistoryLimit()

        XCTAssertEqual(store.items.count, ClipboardStore.minHistoryCount)
        XCTAssertFalse(store.items.contains { $0.text == "item 0" }, "the newest were trimmed")
        XCTAssertTrue(store.items.contains { $0.text == "item 699" })
    }
}

/// The editor's text view, and the toolbar commands that act on it.
@MainActor
final class EditorTextViewTests: XCTestCase {

    private func editor(_ text: String) -> (EditSession, NSTextView) {
        let session = EditSession()
        session.begin(with: NSAttributedString(string: text, attributes: ItemEdit.plainDefaults))
        let (_, view) = makeScrollableTextView()
        view.isRichText = true
        view.textStorage?.setAttributedString(session.seed)
        session.attach(view)
        return (session, view)
    }

    func testACommandChangesTheSelectionAndNothingElse() throws {
        let (session, view) = editor("Enjoy car driving simulator")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        session.run(.bold)

        let storage = try XCTUnwrap(view.textStorage)
        let manager = NSFontManager.shared
        let inside = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let outside = try XCTUnwrap(storage.attribute(.font, at: 10, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(manager.traits(of: inside).contains(.boldFontMask))
        XCTAssertFalse(manager.traits(of: outside).contains(.boldFontMask),
                       "the command ran past the selection")
    }

    /// A command does not depend on the text view holding first responder — which is what said the
    /// old "chose a colour, nothing happened" symptom was the click never arriving at the visible
    /// editor, not the command failing. See `EditWindowPresenter`.
    func testACommandStillAppliesWhenTheViewIsNotFirstResponder() throws {
        let (session, view) = editor("Enjoy car driving simulator")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        _ = view.window?.makeFirstResponder(nil)

        session.run(.bold)

        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5),
                       "the selection was lost, so the command had nothing to act on")
        let applied = try XCTUnwrap(try XCTUnwrap(view.textStorage)
            .attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: applied).contains(.boldFontMask))
    }

    /// The I-beam has to come from a tracking area, not from a cursor rect: xPaste is never the
    /// active application, and cursor rects are only honoured for the one that is.
    func testTheTextViewCarriesAnAlwaysActiveCursorArea() {
        let (_, view) = makeScrollableTextView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        view.updateTrackingAreas()

        let ours = view.trackingAreas.filter {
            $0.options.contains(.activeAlways) && $0.options.contains(.cursorUpdate)
        }
        XCTAssertEqual(ours.count, 1)
    }

    /// And `updateTrackingAreas` runs on every resize, so it must not stack them up.
    func testTheCursorAreaIsNotDuplicatedOnEveryLayout() {
        let (_, view) = makeScrollableTextView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        for _ in 0..<5 { view.updateTrackingAreas() }

        let ours = view.trackingAreas.filter {
            $0.options.contains(.activeAlways) && $0.options.contains(.cursorUpdate)
        }
        XCTAssertEqual(ours.count, 1, "a tracking area was added per layout pass")
    }
}

/// The editor window's own chrome.
@MainActor
final class EditWindowTests: XCTestCase {

    override func tearDown() {
        EditWindowPresenter.shared.dismiss()
        super.tearDown()
    }

    /// One editor, ever. Two of them on screen at once is what made a colour chosen for the visible
    /// selection land on the hidden document — see `EditWindowPresenter`.
    func testPresentingTwiceLeavesOnlyOneEditor() {
        EditWindowPresenter.shared.present(ClipboardItem(type: .text, text: "một"))
        XCTAssertTrue(EditWindowPresenter.shared.isOpen)
        EditWindowPresenter.shared.present(ClipboardItem(type: .text, text: "hai"))
        XCTAssertTrue(EditWindowPresenter.shared.isOpen)

        let editors = NSApp.windows.filter { $0.identifier == EditWindowPresenter.windowIdentifier }
        XCTAssertEqual(editors.filter(\.isVisible).count, 1, "a second editor was left on screen")
    }

    /// And it closes by being closed — the popover's own button ran a state change that could
    /// fail to arrive, which is how one got stuck on screen with no way to dismiss it.
    func testDismissTakesTheWindowAway() {
        EditWindowPresenter.shared.present(ClipboardItem(type: .text, text: "xin chào"))
        EditWindowPresenter.shared.dismiss()

        XCTAssertFalse(EditWindowPresenter.shared.isOpen)
        let visible = NSApp.windows
            .filter { $0.identifier == EditWindowPresenter.windowIdentifier }
            .filter(\.isVisible)
        XCTAssertTrue(visible.isEmpty)
    }

    /// Kinds that have nothing to type into never open one.
    func testOnlyEditableKindsOpenAnEditor() {
        EditWindowPresenter.shared.present(ClipboardItem(type: .image, imageData: Data([1, 2, 3])))
        XCTAssertFalse(EditWindowPresenter.shared.isOpen)
        EditWindowPresenter.shared.present(
            ClipboardItem(type: .file, fileURLs: [URL(fileURLWithPath: "/tmp/x")]))
        XCTAssertFalse(EditWindowPresenter.shared.isOpen)
    }

    /// The footer's "Open in …" appears exactly when what is in the editor is a link — including
    /// one typed into an item that started as prose, which is what the card will become on save.
    func testTheFooterOffersToOpenWhateverIsALink() {
        XCTAssertEqual(EditWindowView.link(in: "https://example.com"),
                       URL(string: "https://example.com"))
        XCTAssertEqual(EditWindowView.link(in: "  http://example.com/a?b=1  "),
                       URL(string: "http://example.com/a?b=1"))
        XCTAssertNil(EditWindowView.link(in: "Enjoy car driving simulator"))
        XCTAssertNil(EditWindowView.link(in: ""))
        // Only what can actually be opened — the same rule the card files a Link by.
        XCTAssertNil(EditWindowView.link(in: "mailto:someone@example.com"))
        XCTAssertNil(EditWindowView.link(in: "file:///tmp/x"))
    }

    func testTheFooterCountsTheWayPasteDoes() {
        XCTAssertEqual(EditWindowView.describe("dfgdfgfdgdfgdfgdf"),
                       "17 characters  ·  1 words  ·  1 lines")
        XCTAssertEqual(EditWindowView.describe(""), "0 characters  ·  0 words  ·  0 lines")
        XCTAssertEqual(EditWindowView.describe("a b\nc"), "5 characters  ·  3 words  ·  2 lines")
    }
}

/// How a colour literal is shown, as against how it is stored.
final class ColourLiteralDisplayTests: XCTestCase {

    func testHexIsShownInUpperCase() {
        XCTAssertEqual(ColorParser.displayLiteral("#ffffff"), "#FFFFFF")
        XCTAssertEqual(ColorParser.displayLiteral("#1e90ff"), "#1E90FF")
        XCTAssertEqual(ColorParser.displayLiteral("#FFF"), "#FFF")
    }

    /// Every hex length, not only the six-digit one: a short form left in lower case beside an
    /// upper-cased neighbour is the inconsistency this exists to remove.
    func testEveryHexLengthIsCovered() {
        XCTAssertEqual(ColorParser.displayLiteral("#fff"), "#FFF")
        XCTAssertEqual(ColorParser.displayLiteral("#fffa"), "#FFFA")
        XCTAssertEqual(ColorParser.displayLiteral("#ff00aa80"), "#FF00AA80")
    }

    /// Function syntax is left alone — `RGB(255, 255, 255)` is not how anybody writes one.
    func testFunctionalNotationIsUntouched() {
        XCTAssertEqual(ColorParser.displayLiteral("rgb(255, 255, 255)"), "rgb(255, 255, 255)")
        XCTAssertEqual(ColorParser.displayLiteral("hsla(210, 100%, 56%, 0.5)"),
                       "hsla(210, 100%, 56%, 0.5)")
    }

    /// Anything that is not a hex literal comes back byte for byte.
    func testNonColourTextIsUntouched() {
        XCTAssertEqual(ColorParser.displayLiteral("#zzzzzz"), "#zzzzzz")
        XCTAssertEqual(ColorParser.displayLiteral("#ffff"), "#FFFF")
        XCTAssertEqual(ColorParser.displayLiteral("#fffff"), "#fffff", "five digits is not a colour")
        XCTAssertEqual(ColorParser.displayLiteral("hello"), "hello")
        XCTAssertEqual(ColorParser.displayLiteral(""), "")
    }

    /// The point of the whole thing: the item itself never changes, so a paste is what was copied.
    func testTheStoredItemIsNotRewritten() {
        let item = ClipboardItem(type: .color, text: "#ffffff")
        XCTAssertEqual(item.text, "#ffffff")
        XCTAssertEqual(ColorParser.displayLiteral(item.text ?? ""), "#FFFFFF")

        let board = NSPasteboard(name: .init("Colour-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        item.write(to: board)
        XCTAssertEqual(board.string(forType: .string), "#ffffff",
                       "the card's upper case leaked into what gets pasted")
    }
}

/// Editing a colour: the notation it keeps, and the readings under the swatch.
@MainActor
final class ColourEditTests: XCTestCase {

    override func tearDown() {
        EditWindowPresenter.shared.dismiss()
        super.tearDown()
    }

    /// A colour picked from the system panel is written back in the notation the item arrived in —
    /// an `rgb(…)` item does not silently become hex because that is what the picker thinks in.
    func testTheOriginalNotationIsKept() {
        XCTAssertEqual(ColourDraft.format(of: "#1e90ff"), .hex)
        XCTAssertEqual(ColourDraft.format(of: "rgb(30, 144, 255)"), .rgb)
        XCTAssertEqual(ColourDraft.format(of: "hsla(210, 100%, 56%, 0.5)"), .hsl)
        XCTAssertEqual(ColourDraft.format(of: "  RGB(1, 2, 3)  "), .rgb)

        let draft = ColourDraft(literal: "rgb(30, 144, 255)")
        draft.take(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(draft.literal, "rgb(255, 0, 0)")
    }

    func testTakingAColourKeepsHexAsHex() {
        let draft = ColourDraft(literal: "#1e90ff")
        draft.take(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(draft.literal, "#000000")
    }

    /// Every reading at once, the way Paste puts them under the swatch — and 255, not 256.
    func testTheReadingsUnderTheSwatch() {
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertEqual(ColourDraft.readings(for: white),
                       "RGB 255, 255, 255  ·  HSL 0, 0, 100  ·  HSB 0, 0, 100")
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(ColourDraft.readings(for: red),
                       "RGB 255, 0, 0  ·  HSL 0, 100, 50  ·  HSB 0, 100, 100")
    }

    /// Text the picker can no longer make sense of leaves the draft without a colour, and Save
    /// refuses rather than writing something that is not one.
    func testTextThatIsNoLongerAColourHasNoColour() {
        let draft = ColourDraft(literal: "#1e90ff")
        XCTAssertNotNil(draft.colour)
        draft.literal = "not a colour"
        XCTAssertNil(draft.colour)
    }

    /// The colour editor is a window like any other, and closing it takes the system picker down
    /// with it — a picker left messaging a draft that no longer exists is the leak this avoids.
    func testClosingTheEditorTakesThePickerWithIt() {
        EditWindowPresenter.shared.present(ClipboardItem(type: .color, text: "#1e90ff"))
        XCTAssertTrue(EditWindowPresenter.shared.isOpen)
        XCTAssertTrue(EditWindowPresenter.shared.isColourPickerAttached)

        EditWindowPresenter.shared.dismiss()

        XCTAssertFalse(EditWindowPresenter.shared.isOpen)
        XCTAssertFalse(EditWindowPresenter.shared.isColourPickerAttached)
    }
}

/// The colour picker beside the editor.
@MainActor
final class ColourPickerTests: XCTestCase {

    override func tearDown() {
        EditWindowPresenter.shared.dismiss()
        super.tearDown()
    }

    /// It was opening all along — at `.floating` (3), underneath an editor at `.statusBar + 1`
    /// (26) and underneath every other floating window on screen, which is indistinguishable from
    /// never opening.
    func testThePickerSitsAtTheEditorsLevel() throws {
        EditWindowPresenter.shared.present(ClipboardItem(type: .color, text: "#1e90ff"))

        let editor = try XCTUnwrap(NSApp.windows
            .first { $0.identifier == EditWindowPresenter.windowIdentifier })
        XCTAssertTrue(NSColorPanel.shared.isVisible)
        XCTAssertEqual(NSColorPanel.shared.level, editor.level,
                       "the picker is below the editor, so it cannot be seen")
    }

    func testThePickerOpensOnTheItemsOwnColour() throws {
        EditWindowPresenter.shared.present(ClipboardItem(type: .color, text: "#1e90ff"))
        let shown = try XCTUnwrap(NSColorPanel.shared.color.usingColorSpace(.sRGB))
        XCTAssertEqual(ColorFormat.hex.render(shown), "#1e90ff")
    }

    /// Typing a different notation over the code changes what a later turn of the wheel writes —
    /// the field is the source of truth, not the notation the item happened to arrive in.
    func testTypingANotationChangesWhatTheWheelWritesBack() {
        let draft = ColourDraft(literal: "#1e90ff")
        XCTAssertEqual(draft.format, .hex)

        draft.literal = "rgb(255, 0, 0)"
        XCTAssertEqual(draft.format, .rgb)
        draft.take(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        XCTAssertEqual(draft.literal, "rgb(0, 255, 0)")
    }

    /// Half-typed text is left exactly as typed: the swatch simply has no colour until it parses
    /// again, rather than the field being corrected underneath the caret.
    func testHalfTypedTextIsNotRewritten() {
        let draft = ColourDraft(literal: "#1e90ff")
        draft.literal = "#1e90f"
        XCTAssertEqual(draft.literal, "#1e90f")
        XCTAssertNil(draft.colour)
        draft.literal = "#1e90ff"
        XCTAssertNotNil(draft.colour)
    }
}
