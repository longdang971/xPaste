import AppKit

extension NSImage {
    /// Roughly what this picture occupies once its pixels are decoded.
    ///
    /// The number every image cache in the app is bounded by. `NSCache.countLimit` bounds how
    /// *many* pictures are held, which says nothing at all about memory: a 2200x1400 screenshot is
    /// 12 MB of pixels and fifty of them are six hundred. Measured on a real run, twenty-five large
    /// copies took the app from 98 MB to 456 MB while only 15 MB reached disk.
    ///
    /// Read off the representations rather than `size`, which is in points and reports half the
    /// number for anything captured on a 2x display. Four bytes per pixel, RGBA.
    var approximateDecodedBytes: Int {
        let pixels = representations.reduce(0) { $0 + max(0, $1.pixelsWide * $1.pixelsHigh) }
        return max(pixels * 4, 1)
    }

    /// The bytes to store for this image: PNG when it has transparency to keep, JPEG otherwise.
    ///
    /// JPEG has no alpha channel. Encoding a cut-out logo as one composites it onto an opaque
    /// plate, which is how a transparent PNG ended up sitting on a white rectangle on its card —
    /// the card was drawing exactly what had been stored.
    ///
    /// PNG is several times larger for a photograph or a screenshot, so it is only reached for by
    /// images that actually use their alpha channel, and an oversized one is scaled down rather
    /// than re-encoded as JPEG: falling back would quietly paint the transparency over again.
    func compressedData(maxBytes: Int) -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.compressedData(maxBytes: maxBytes)
    }
}

extension NSBitmapImageRep {
    /// The bytes to store, decided from a bitmap that already exists.
    ///
    /// The route in from the pasteboard uses this directly, because going through `NSImage` costs
    /// the picture twice over: `NSImage` holds the bytes it was made from, `tiffRepresentation`
    /// renders a *fresh* TIFF from them, and `NSBitmapImageRep(data:)` then decodes that back into
    /// pixels. On a 5120x2880 screen capture each of those is 59 MB, so three of them is most of
    /// what a copy costs — and the allocator keeps the freed pages, which is why the footprint of a
    /// menu-bar app climbed into the hundreds of megabytes after a handful of screenshots.
    func compressedData(maxBytes: Int) -> Data? {
        usesTransparency ? pngData(maxBytes: maxBytes) : jpegData(maxBytes: maxBytes)
    }
}

extension NSBitmapImageRep {
    /// Whether any pixel is actually not fully opaque.
    ///
    /// `hasAlpha` only says the channel exists. A screenshot carries one and never uses it, and a
    /// screenshot is the commonest thing anyone copies — treating those as transparent would
    /// multiply the stored size of nearly every image for nothing.
    ///
    /// A full scan, but it exits at the first transparent pixel, and a cut-out image is transparent
    /// in its very first row. The whole-image case is an opaque picture, and this runs on the
    /// background task that already does the encoding.
    var usesTransparency: Bool {
        guard hasAlpha else { return false }
        guard let rep = scannableRep, let data = rep.bitmapData else { return true }

        let samples = rep.samplesPerPixel
        let alphaOffset = rep.bitmapFormat.contains(.alphaFirst) ? 0 : samples - 1
        for y in 0..<rep.pixelsHigh {
            let row = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide where row[x * samples + alphaOffset] != 0xFF {
                return true
            }
        }
        return false
    }

    /// This bitmap in the one layout the alpha scan reads: 8-bit integer samples, interleaved,
    /// alpha in a channel of its own.
    ///
    /// Re-rendered when it is anything else, rather than the scan growing a branch per format.
    /// That is not a rare path — an image drawn on a wide-gamut display comes back as 16-bit
    /// *half-floats*, where an opaque alpha is 0x3C00 and not 0xFF at all. Reading those bytes as
    /// integers said "transparent" for every ordinary screenshot.
    private var scannableRep: NSBitmapImageRep? {
        if !isPlanar,
           !bitmapFormat.contains(.floatingPointSamples),
           bitsPerSample == 8,
           samplesPerPixel == 2 || samplesPerPixel == 4,
           bitmapData != nil {
            return self
        }
        return scaled(by: 1)
    }

    /// JPEG bytes within `maxBytes`: drop the quality first, then shrink the picture.
    ///
    /// The shrinking half is what stops a detailed image being lost altogether. Quality alone
    /// bottoms out around 0.10, and a photograph or a busy screenshot still exceeds a megabyte
    /// there — at which point the old code returned nil and `ClipboardMonitor` dropped the copy on
    /// the floor, so it never reached the history and the user never learned why. The PNG path
    /// below had always shrunk rather than given up; this is the same ladder.
    func jpegData(maxBytes: Int) -> Data? {
        var candidate: NSBitmapImageRep? = self
        var scale: CGFloat = 1
        while let rep = candidate {
            var quality: Double = 0.85
            while quality > 0.09 {
                if let data = rep.representation(using: .jpeg,
                                                 properties: [.compressionFactor: quality]),
                   data.count <= maxBytes {
                    return data
                }
                quality -= 0.25
            }
            scale *= 0.7
            guard scale >= 0.2 else { return nil }
            candidate = scaled(by: scale)
        }
        return nil
    }

    /// PNG bytes within `maxBytes`, shrinking the picture until they fit.
    ///
    /// Returns nil once shrinking stops being worth it — the caller drops the item, which is what
    /// it already did for a photograph that would not compress far enough.
    func pngData(maxBytes: Int) -> Data? {
        var candidate: NSBitmapImageRep? = self
        var scale: CGFloat = 1
        while let rep = candidate {
            if let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes {
                return png
            }
            scale *= 0.7
            guard scale >= 0.2 else { return nil }
            candidate = scaled(by: scale)
        }
        return nil
    }

    /// A copy at `scale`, alpha preserved.
    func scaled(by scale: CGFloat) -> NSBitmapImageRep? {
        let width = Int((CGFloat(pixelsWide) * scale).rounded())
        let height = Int((CGFloat(pixelsHigh) * scale).rounded())
        guard width > 0, height > 0,
              let target = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        target.size = NSSize(width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        return target
    }
}
