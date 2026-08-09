import XCTest
import AppKit
@testable import xPaste

/// The two pieces of the drag session that can be checked without a session: what each item looks
/// like on the pasteboard when the target is meant to handle the drop, and the picture the drag
/// carries.
///
/// The picture matters more than it looks. It is rendered from the card's layer because
/// `cacheDisplay` comes back empty for SwiftUI-hosted views, and a silent failure there means
/// dragging a card shows nothing at all — which no screenshot can catch reliably, since the window
/// server draws drag images in a layer screen captures do not include.
final class CardDragSourceTests: XCTestCase {

    // MARK: - Native payloads

    func testTextTravelsAsAString() {
        let item = ClipboardItem(type: .text, text: "hello")
        XCTAssertEqual(CardDragSourceView.nativeWriter(for: item) as? NSString, "hello")
    }

    /// A link travels as a URL so a browser opens it and a note app makes it clickable, rather than
    /// receiving the characters of the address.
    func testALinkTravelsAsAURL() {
        let item = ClipboardItem(type: .url, text: "https://example.com/x")
        XCTAssertEqual(CardDragSourceView.nativeWriter(for: item) as? NSURL,
                       URL(string: "https://example.com/x")! as NSURL)
    }

    /// A file travels as the real file, which is what makes Finder copy it and a web upload zone
    /// accept it — the whole reason files keep the native payload.
    func testAFileTravelsAsItsURL() {
        let url = URL(fileURLWithPath: "/tmp/xpaste-test-file.txt")
        let item = ClipboardItem(type: .file, fileURLs: [url])
        XCTAssertEqual(CardDragSourceView.nativeWriter(for: item) as? NSURL, url as NSURL)
    }

    /// An item whose picture is not on disk still has to travel as a picture, from the bytes it
    /// carries.
    func testAnImageWithNoFileOnDiskTravelsAsTheBitmap() {
        let bitmap = NSImage(size: NSSize(width: 4, height: 4))
        bitmap.lockFocus()
        NSColor.green.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        bitmap.unlockFocus()
        guard let data = bitmap.tiffRepresentation else { return XCTFail("no bitmap data") }
        let item = ClipboardItem(type: .image, imageData: data)
        XCTAssertNotNil(CardDragSourceView.nativeWriter(for: item) as? NSImage)
    }

    /// An item carrying nothing to build a URL or a file from still has to travel as something, so
    /// it goes as the text the card shows. `.url` items always hold a real address in practice —
    /// that is the only way one is created — so this is the corrupt-data path, not a normal one.
    func testAnItemWithNoTextOfItsOwnTravelsAsWhatTheCardShows() {
        let item = ClipboardItem(type: .url, text: nil)
        XCTAssertEqual(CardDragSourceView.nativeWriter(for: item) as? NSString,
                       item.displayText as NSString)
    }

    /// A file item with no file left to point at falls back the same way, rather than handing over an
    /// empty URL that a target would reject.
    func testAFileItemWithNoURLTravelsAsWhatTheCardShows() {
        let item = ClipboardItem(type: .file, text: "some/path", fileURLs: nil)
        XCTAssertEqual(CardDragSourceView.nativeWriter(for: item) as? NSString, "some/path")
    }

    // MARK: - The drag image

    /// Builds a real layer-backed view in a real window, because that is the only thing
    /// `layer.render(in:)` has anything to say about.
    private func hostedView(color: NSColor, size: NSSize) -> NSView {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        window.contentView = view
        window.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return view
    }

    func testTheDragImageIsTheSizeOfTheCard() {
        let view = hostedView(color: .red, size: NSSize(width: 60, height: 40))
        let image = CardDragSourceView.snapshot(of: view, badge: 1)
        XCTAssertEqual(image?.size, NSSize(width: 60, height: 40))
    }

    /// The point of the test: an empty render is the failure mode, so look at the pixels.
    func testTheDragImageActuallyHasTheCardInIt() {
        let view = hostedView(color: .red, size: NSSize(width: 60, height: 40))
        guard let image = CardDragSourceView.snapshot(of: view, badge: 1),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let centre = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        else { return XCTFail("no drag image") }
        let red = centre.usingColorSpace(.deviceRGB)
        XCTAssertEqual(red?.redComponent ?? 0, 1, accuracy: 0.05, "the card must be in the picture")
        XCTAssertLessThan(red?.blueComponent ?? 1, 0.2)
    }

    func testAViewWithNoSizeHasNoDragImage() {
        let view = hostedView(color: .red, size: NSSize(width: 0, height: 0))
        XCTAssertNil(CardDragSourceView.snapshot(of: view, badge: 1))
    }

    func testThereIsNoDragImageWithoutAView() {
        XCTAssertNil(CardDragSourceView.snapshot(of: nil, badge: 1))
    }

    /// Dragging a group draws the count on the picture, so it is obvious more than one card is
    /// travelling. The badge sits in the top-right corner.
    func testAGroupGetsACountDrawnOnIt() {
        let view = hostedView(color: .red, size: NSSize(width: 60, height: 40))
        guard let plain = CardDragSourceView.snapshot(of: view, badge: 1),
              let badged = CardDragSourceView.snapshot(of: view, badge: 3),
              let plainRep = NSBitmapImageRep(data: plain.tiffRepresentation!),
              let badgedRep = NSBitmapImageRep(data: badged.tiffRepresentation!)
        else { return XCTFail("no drag image") }
        XCTAssertEqual(badged.size, plain.size, "the badge must not resize the picture")
        // The badge is drawn near the top-right; in a bitmap rep row 0 is the top.
        let x = badgedRep.pixelsWide - 20, y = 20
        XCTAssertNotEqual(badgedRep.colorAt(x: x, y: y)?.redComponent,
                          plainRep.colorAt(x: x, y: y)?.redComponent,
                          "the corner should have changed where the badge lands")
    }
}
