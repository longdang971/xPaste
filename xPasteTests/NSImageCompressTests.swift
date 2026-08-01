import XCTest
import AppKit
@testable import xPaste

/// The stored bytes for an image item. The bug these pin: everything was encoded as JPEG, which
/// has no alpha channel, so a transparent PNG was composited onto an opaque plate on its way to
/// disk — and the card faithfully drew the plate.
final class NSImageCompressTests: XCTestCase {

    /// A square with a fully transparent left half and an opaque red right half.
    private func halfTransparentImage(side: Int = 64) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: side / 2, y: 0, width: side / 2, height: side)).fill()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// The same square, opaque everywhere — a stand-in for the screenshot case.
    private func opaqueImage(side: Int = 64) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        image.unlockFocus()
        return image
    }

    private func bitmap(of data: Data) -> NSBitmapImageRep? {
        NSBitmapImageRep(data: data)
    }

    // MARK: - What gets kept

    func test_a_transparent_image_keeps_its_transparency() throws {
        let data = try XCTUnwrap(halfTransparentImage().compressedData(maxBytes: 1_000_000),
                                "a small transparent image must be storable")
        let rep = try XCTUnwrap(bitmap(of: data), "stored bytes did not decode")

        XCTAssertTrue(rep.hasAlpha, "the stored image lost its alpha channel")
        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2), "could not read the transparent half")
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.02,
                       "the transparent half came back opaque — it was flattened onto a plate")
    }

    func test_the_opaque_half_survives_too() throws {
        let data = try XCTUnwrap(halfTransparentImage().compressedData(maxBytes: 1_000_000))
        let rep = try XCTUnwrap(bitmap(of: data))
        let painted = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 3, y: 2))

        XCTAssertEqual(painted.alphaComponent, 1, accuracy: 0.02)
        XCTAssertGreaterThan(painted.redComponent, 0.8, "the red half should still be red")
    }

    /// The reason this is not simply "always PNG": a screenshot carries an alpha channel it never
    /// uses, and PNG-ing every one of those would multiply the size of the commonest copy there is.
    func test_an_opaque_image_is_not_stored_as_png() throws {
        let data = try XCTUnwrap(opaqueImage().compressedData(maxBytes: 1_000_000))
        XCTAssertFalse(data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
                       "an opaque image has no transparency to protect, so it should take JPEG")
        XCTAssertTrue(data.starts(with: [0xFF, 0xD8]), "expected JPEG bytes")
    }

    func test_a_transparent_image_is_stored_as_png() throws {
        let data = try XCTUnwrap(halfTransparentImage().compressedData(maxBytes: 1_000_000))
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "expected PNG bytes")
    }

    // MARK: - The alpha-usage test itself

    func test_transparency_is_measured_by_pixels_not_by_the_channel() throws {
        let opaqueRep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(opaqueImage().tiffRepresentation)))
        let cutOutRep = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(halfTransparentImage().tiffRepresentation)))

        XCTAssertFalse(opaqueRep.usesTransparency,
                       "an opaque image must not be called transparent just for having the channel")
        XCTAssertTrue(cutOutRep.usesTransparency)
    }

    // MARK: - Oversize transparent images

    /// Falling back to JPEG here would paint the transparency over — the very bug being fixed — so
    /// an oversize transparent image is scaled down instead, and stays a PNG.
    func test_an_oversize_transparent_image_is_scaled_rather_than_flattened() throws {
        let big = halfTransparentImage(side: 900)
        let data = try XCTUnwrap(big.compressedData(maxBytes: 4_000),
                                 "a transparent image should be shrunk to fit, not dropped")

        XCTAssertLessThanOrEqual(data.count, 4_000)
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "it must still be a PNG")

        let rep = try XCTUnwrap(bitmap(of: data))
        XCTAssertLessThan(rep.pixelsWide, 900, "it should have been scaled down to fit the cap")
        let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1))
        XCTAssertEqual(corner.alphaComponent, 0, accuracy: 0.02,
                       "scaling must not cost the transparency")
    }
}
