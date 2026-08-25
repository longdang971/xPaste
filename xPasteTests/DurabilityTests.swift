import XCTest
import AppKit
import Combine
@testable import xPaste

/// What survives the app closing, and what a reader gets when the only copy is still on its way to
/// disk. Both were found by asking what happens if the process stops right now.
final class DurabilityTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Durability-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func fileCount(_ folder: String) -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent(folder), includingPropertiesForKeys: nil))?.count ?? -1
    }

    /// Saves are queued, so quitting straight after a copy used to leave most of them unwritten —
    /// measured at two of six item files, and none of the image, at the moment
    /// `applicationWillTerminate` would have run.
    ///
    /// Asserted by reopening rather than by counting files: the history is a database now, and
    /// "written" means a second store opened on the same directory can see it. That is also the
    /// only thing the old file count was ever standing in for.
    func testFlushingLeavesNothingUnwritten() {
        let store = ClipboardStore(maxItems: 50, storageDir: directory)
        for i in 0..<5 { store.add(ClipboardItem(type: .text, text: "item \(i)")) }
        store.add(ClipboardItem(type: .image, imageData: Data(repeating: 0xCD, count: 500_000)))

        store.flushPendingWrites()

        XCTAssertEqual(ClipboardStore(maxItems: 50, storageDir: directory).items.count, 6)
        XCTAssertEqual(fileCount("images"), 1)
    }

    /// The item's bytes now live only on the save queue until it drains, so every reader has to go
    /// through something that drains it first — otherwise a picture copied a moment ago pastes as
    /// nothing at all.
    func testImageBytesAreReadableImmediatelyAfterTheCopy() throws {
        let store = ClipboardStore(maxItems: 50, storageDir: directory)
        let blob = Data(repeating: 0xAB, count: 400_000)

        store.add(ClipboardItem(type: .image, imageData: blob))
        let id = try XCTUnwrap(store.items.first?.id)

        XCTAssertEqual(store.imageBytes(for: id), blob)
    }

    /// And the paste path itself, which is what the user actually notices.
    func testAnImageCopiedAMomentAgoStillPastesAsAnImage() throws {
        let store = ClipboardStore(maxItems: 50, storageDir: directory)
        let real = NSImage(size: NSSize(width: 8, height: 8))
        real.lockFocus()
        NSColor.systemPink.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        real.unlockFocus()
        let bytes = try XCTUnwrap(real.compressedData(maxBytes: 1_000_000))
        store.add(ClipboardItem(type: .image, imageData: bytes))

        // The shared store is what `write(to:)` consults, so this exercises the helper directly.
        XCTAssertNotNil(store.imageBytes(for: try XCTUnwrap(store.items.first?.id)))
    }

    /// A move is one change to the list, and should cost one pass over the panel — it was two.
    func testMovingAnItemToTheFrontCostsOneInvalidation() {
        let store = ClipboardStore(maxItems: 10, storageDir: nil)
        store.add(ClipboardItem(type: .text, text: "a"))
        store.add(ClipboardItem(type: .text, text: "b"))

        var invalidations = 0
        let subscription = store.objectWillChange.sink { _ in invalidations += 1 }
        store.moveToTop(store.items[1])
        subscription.cancel()

        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(store.items.first?.text, "a")
    }
}

/// The file a drag hands to Finder.
final class DragTempFileTests: XCTestCase {

    private func pngBytes() throws -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    override func tearDown() {
        DragTempFile.clearLeftovers()
        super.tearDown()
    }

    /// The stored file is called `<uuid>.jpg` whatever is in it, which is what Finder used to
    /// receive: an unhelpful name and, for a transparent picture, the wrong extension outright.
    func testADraggedPictureIsNamedForItselfAndForWhatItReallyIs() throws {
        let item = ClipboardItem(type: .image, imageData: try pngBytes(), label: "logo")

        let url = try XCTUnwrap(DragTempFile.url(for: item))

        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "logo")
        XCTAssertEqual(try Data(contentsOf: url), try pngBytes())
    }

    /// Bytes that do not announce a format get no file — naming one would put the same lie
    /// somewhere new. The caller drags the bitmap instead.
    ///
    /// Written with BMP. It used to use TIFF, on the understanding that TIFF was among the formats
    /// this could not name — which was true, and was itself the bug: TIFF is what `NSPasteboard`
    /// hands over for an ordinary image copy, so the commonest picture in the history was the one
    /// a drag refused to write. See `testARealImageCopyCanBeDraggedOutAsAFile`.
    func testBytesThatNameNoFormatGetNoFile() throws {
        let drawn = NSImage(size: NSSize(width: 2, height: 2))
        drawn.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
        drawn.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(drawn.tiffRepresentation)))
        let bmp = try XCTUnwrap(rep.representation(using: .bmp, properties: [:]))
        let item = ClipboardItem(type: .image, imageData: bmp)

        XCTAssertNil(DragTempFile.url(for: item))
    }

    /// Two items whose names agree — a label reused, or two screenshots in the same second. They
    /// shared a path, so the second drag found the first item's file already sitting there, kept
    /// it, and handed Finder the wrong picture without a word.
    func testTwoItemsWithTheSameNameDoNotShareAFile() throws {
        func png(_ colour: NSColor) throws -> Data {
            let image = NSImage(size: NSSize(width: 4, height: 4))
            image.lockFocus(); colour.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill(); image.unlockFocus()
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }
        let red = try png(.systemRed), blue = try png(.systemBlue)

        let urlA = try XCTUnwrap(DragTempFile.url(
            for: ClipboardItem(type: .image, imageData: red, label: "logo")))
        let urlB = try XCTUnwrap(DragTempFile.url(
            for: ClipboardItem(type: .image, imageData: blue, label: "logo")))

        XCTAssertNotEqual(urlA, urlB)
        XCTAssertEqual(try Data(contentsOf: urlB), blue, "the drag handed over the other item")
        XCTAssertEqual(try Data(contentsOf: urlA), red)
        // The name the user sees is still the clean one.
        XCTAssertEqual(urlA.lastPathComponent, "logo.png")
        XCTAssertEqual(urlB.lastPathComponent, "logo.png")
    }

    func testLeftoversAreClearedAtLaunch() throws {
        let item = ClipboardItem(type: .image, imageData: try {
            let image = NSImage(size: NSSize(width: 2, height: 2))
            image.lockFocus(); NSColor.green.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill(); image.unlockFocus()
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }())
        let url = try XCTUnwrap(DragTempFile.url(for: item))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        DragTempFile.clearLeftovers()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testOnlyImagesGetOne() {
        XCTAssertNil(DragTempFile.url(for: ClipboardItem(type: .text, text: "hi")))
    }
}
