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

    // MARK: - Giving up vs shrinking

    /// A detailed picture past the byte budget used to come back nil, and `ClipboardMonitor` drops
    /// the copy when that happens — so a photograph or a busy screenshot never reached the history
    /// and the user was never told why. Quality alone bottoms out around 0.10; the picture has to
    /// shrink as well, which is what the PNG path had always done.
    func test_a_detailed_image_shrinks_rather_than_being_dropped() throws {
        let noisy = try XCTUnwrap(Self.noise(width: 2880, height: 1800))

        let data = try XCTUnwrap(noisy.compressedData(maxBytes: 1_000_000),
                                 "the copy would have been dropped entirely")

        XCTAssertLessThanOrEqual(data.count, 1_000_000)
        XCTAssertNotNil(NSImage(data: data), "what was stored is not a readable image")
    }

    func test_a_detailed_transparent_image_also_shrinks_rather_than_being_dropped() throws {
        let noisy = try XCTUnwrap(Self.noise(width: 2400, height: 1600, alpha: 0.5))

        let data = try XCTUnwrap(noisy.compressedData(maxBytes: 1_000_000))

        XCTAssertLessThanOrEqual(data.count, 1_000_000)
    }

    /// Noise on purpose: a flat colour compresses to nothing and would prove nothing.
    private static func noise(width: Int, height: Int, alpha: CGFloat = 1) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let data = rep.bitmapData else { return nil }
        var seed: UInt64 = 0x2545F4914F6CDD1D
        for i in stride(from: 0, to: rep.bytesPerRow * height, by: 4) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            data[i]     = UInt8(truncatingIfNeeded: seed)
            data[i + 1] = UInt8(truncatingIfNeeded: seed >> 8)
            data[i + 2] = UInt8(truncatingIfNeeded: seed >> 16)
            data[i + 3] = UInt8(alpha * 255)
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}

extension NSImageCompressTests {
    /// The pasteboard hands over encoded bytes, and turning those into an `NSImage` first cost the
    /// picture twice more: `NSImage` keeps the bytes, `tiffRepresentation` renders a fresh TIFF,
    /// and that is decoded back into pixels. Compressing straight from the bitmap is the same
    /// answer for a third of the memory.
    func test_compressing_a_bitmap_directly_matches_going_through_NSImage() throws {
        let image = NSImage(size: NSSize(width: 200, height: 120))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 120)).fill()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(x: 10, y: 10, width: 40, height: 40)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        let viaImage = try XCTUnwrap(image.compressedData(maxBytes: 1_000_000))
        let direct = try XCTUnwrap(rep.compressedData(maxBytes: 1_000_000))

        XCTAssertEqual(SaveFormat.imageExtension(for: direct),
                       SaveFormat.imageExtension(for: viaImage))
        let decoded = try XCTUnwrap(NSImage(data: direct))
        XCTAssertEqual(decoded.representations.first?.pixelsWide, rep.pixelsWide)
        XCTAssertEqual(decoded.representations.first?.pixelsHigh, rep.pixelsHigh)
    }

    /// Transparency still routes to PNG when the bitmap is handed over directly.
    func test_a_transparent_bitmap_still_becomes_png() throws {
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus()
        NSColor.systemRed.withAlphaComponent(0.4).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 20, height: 20)).fill()
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))

        let data = try XCTUnwrap(rep.compressedData(maxBytes: 1_000_000))

        XCTAssertEqual(SaveFormat.imageExtension(for: data), "png")
    }
}
