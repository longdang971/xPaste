import XCTest
import AppKit
import SwiftUI
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

    /// Builds the real thing: an `NSHostingView` with SwiftUI content, and a plain view inside it
    /// standing in for the card's overlay. Nothing less is a fair test — the first version of these
    /// tests handed `snapshot` a plain `NSView` with a background colour set on its layer, which
    /// passed while the shipping app produced a completely transparent drag image, because SwiftUI
    /// draws a whole panel into the hosting view's layer and leaves the layers in between empty.
    /// Parked far off any display.
    ///
    /// `orderBack` below is what makes SwiftUI build a display list for the layer — with no window
    /// ordered in, `snapshot` renders nothing and these tests fail for the wrong reason. But an
    /// ordered-in window at the origin is a real window in the bottom-left corner of the screen,
    /// and what these host is `Color.red`: running the suite put red squares on the desktop, the
    /// largest of them a 232pt one, for as long as the test host lived. Off-screen it still draws.
    private static let parkingSpot = NSPoint(x: -30_000, y: -30_000)

    /// Every window `hostedOverlay` made, torn down after each test. AppKit retains an ordered-in
    /// window, so without this they pile up for the length of the run.
    private var hostWindows: [NSWindow] = []

    override func tearDown() {
        hostWindows.forEach { $0.close() }
        hostWindows.removeAll()
        super.tearDown()
    }

    private func hostedOverlay<Content: View>(_ content: Content,
                                              size: NSSize,
                                              overlayFrame: NSRect? = nil) -> NSView {
        let window = NSWindow(contentRect: NSRect(origin: Self.parkingSpot, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // Closing is this class's job (see `tearDown`), not AppKit's — released on close, the
        // window would go away underneath the overlay the caller is still holding.
        window.isReleasedWhenClosed = false
        hostWindows.append(window)
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        // An intermediate view, because that is what production has: SwiftUI wraps the overlay in
        // its own containers, and their layers are the empty ones. Without this the overlay's
        // superview would be the hosting view itself and the test would pass against the very bug it
        // is here to catch.
        let middle = NSView(frame: NSRect(origin: .zero, size: size))
        host.addSubview(middle)
        let overlay = NSView(frame: overlayFrame ?? NSRect(origin: .zero, size: size))
        middle.addSubview(overlay)
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return overlay
    }

    private func bitmap(_ image: NSImage?) -> NSBitmapImageRep? {
        guard let tiff = image?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    func testTheDragImageIsTheSizeOfTheCard() {
        let overlay = hostedOverlay(Color.red, size: NSSize(width: 60, height: 40))
        XCTAssertEqual(CardDragSourceView.snapshot(of: overlay, badge: 1)?.size,
                       NSSize(width: 60, height: 40))
    }

    /// The failure this test exists for: an empty render. A drag whose image is transparent shows the
    /// user nothing but their pointer, and they cannot tell they are dragging at all.
    func testTheDragImageIsNotTransparent() {
        let overlay = hostedOverlay(Color.red, size: NSSize(width: 60, height: 40))
        guard let rep = bitmap(CardDragSourceView.snapshot(of: overlay, badge: 1))
        else { return XCTFail("no drag image") }
        let opaque = (0..<rep.pixelsWide).filter {
            (rep.colorAt(x: $0, y: rep.pixelsHigh / 2)?.alphaComponent ?? 0) > 0.05
        }
        XCTAssertEqual(opaque.count, rep.pixelsWide,
                       "every pixel across the middle should be painted")
    }

    /// The other failure this exists for: `layer.render(in:)` draws into Core Graphics' upward-y space
    /// while the panel is laid out downward-y, so without a mirror the card arrives upside down —
    /// header at the bottom, text inverted.
    func testTheDragImageIsNotUpsideDown() {
        let content = VStack(spacing: 0) { Color.red; Color.blue }
        let overlay = hostedOverlay(content, size: NSSize(width: 40, height: 40))
        guard let rep = bitmap(CardDragSourceView.snapshot(of: overlay, badge: 1))
        else { return XCTFail("no drag image") }
        // Row 0 of a bitmap rep is the top of the picture, which is where the red half belongs.
        let top = rep.colorAt(x: rep.pixelsWide / 2, y: 2)?.usingColorSpace(.deviceRGB)
        let bottom = rep.colorAt(x: rep.pixelsWide / 2,
                                 y: rep.pixelsHigh - 3)?.usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(top?.redComponent ?? 0, 0.5, "the top of the card must stay on top")
        XCTAssertGreaterThan(bottom?.blueComponent ?? 0, 0.5, "the bottom must stay at the bottom")
    }

    /// Only the card is dragged, not the whole panel: the crop has to follow the overlay's frame.
    ///
    /// The frames below are in the intermediate view's coordinates, which are unflipped — y grows
    /// upward — while the hosting view above it is flipped. So y == 20 is the *upper* half of a
    /// 40-point host, which is where the red half of the content is.
    func testTheDragImageIsCroppedToTheOverlay() {
        let content = VStack(spacing: 0) { Color.red; Color.blue }
        let upper = hostedOverlay(content, size: NSSize(width: 40, height: 40),
                                  overlayFrame: NSRect(x: 0, y: 20, width: 40, height: 20))
        guard let rep = bitmap(CardDragSourceView.snapshot(of: upper, badge: 1))
        else { return XCTFail("no drag image") }
        XCTAssertEqual(rep.size.height, 20, "the picture is the overlay's size, not the panel's")
        let colour = rep.colorAt(x: rep.pixelsWide / 2,
                                y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(colour?.redComponent ?? 0, 0.5,
                             "cropping to the upper half must give the red half")
        XCTAssertLessThan(colour?.blueComponent ?? 1, 0.4)
    }

    func testCroppingTheOtherHalfGivesTheOtherColour() {
        let content = VStack(spacing: 0) { Color.red; Color.blue }
        let lower = hostedOverlay(content, size: NSSize(width: 40, height: 40),
                                  overlayFrame: NSRect(x: 0, y: 0, width: 40, height: 20))
        guard let rep = bitmap(CardDragSourceView.snapshot(of: lower, badge: 1))
        else { return XCTFail("no drag image") }
        let colour = rep.colorAt(x: rep.pixelsWide / 2,
                                y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(colour?.blueComponent ?? 0, 0.5,
                             "cropping to the lower half must give the blue half")
    }

    /// The card has rounded corners, so the picture must not carry the panel's background in its
    /// own — that arrived as four white spikes around an otherwise rounded card.
    func testTheDragImageHasNoOpaqueCorners() {
        let overlay = hostedOverlay(Color.red, size: NSSize(width: 232, height: 232))
        guard let rep = bitmap(CardDragSourceView.snapshot(of: overlay, badge: 1))
        else { return XCTFail("no drag image") }
        let corners = [(2, 2), (rep.pixelsWide - 3, 2),
                       (2, rep.pixelsHigh - 3), (rep.pixelsWide - 3, rep.pixelsHigh - 3)]
        for (x, y) in corners {
            XCTAssertLessThan(rep.colorAt(x: x, y: y)?.alphaComponent ?? 1, 0.1,
                              "the corner at \(x),\(y) must be transparent")
        }
        XCTAssertGreaterThan(rep.colorAt(x: rep.pixelsWide / 2,
                                        y: rep.pixelsHigh / 2)?.alphaComponent ?? 0, 0.9,
                             "the middle of the card must still be painted")
    }

    func testAViewWithNoSizeHasNoDragImage() {
        let overlay = hostedOverlay(Color.red, size: NSSize(width: 40, height: 40),
                                    overlayFrame: .zero)
        XCTAssertNil(CardDragSourceView.snapshot(of: overlay, badge: 1))
    }

    func testThereIsNoDragImageWithoutAView() {
        XCTAssertNil(CardDragSourceView.snapshot(of: nil, badge: 1))
    }

    /// A view that is not inside a hosting view has no SwiftUI content to render, and must say so
    /// rather than hand back an empty picture.
    func testAViewOutsideAHostingViewHasNoDragImage() {
        let loose = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        loose.wantsLayer = true
        XCTAssertNil(CardDragSourceView.snapshot(of: loose, badge: 1))
    }

    /// Dragging a group draws the count on the picture, so it is obvious more than one card is
    /// travelling.
    func testAGroupGetsACountDrawnOnIt() {
        let overlay = hostedOverlay(Color.red, size: NSSize(width: 60, height: 40))
        guard let plain = bitmap(CardDragSourceView.snapshot(of: overlay, badge: 1)),
              let badgedImage = CardDragSourceView.snapshot(of: overlay, badge: 3),
              let badged = bitmap(badgedImage)
        else { return XCTFail("no drag image") }
        XCTAssertEqual(badgedImage.size, NSSize(width: 60, height: 40),
                       "the badge must not resize the picture")
        let x = badged.pixelsWide - 20, y = 20
        XCTAssertNotEqual(badged.colorAt(x: x, y: y)?.redComponent,
                          plain.colorAt(x: x, y: y)?.redComponent,
                          "the corner should have changed where the badge lands")
    }
}
