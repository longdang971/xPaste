import AppKit
import Vision

/// Reads text out of clipboard images with Vision, so a screenshot copied two days ago can be
/// found by typing a word that appears inside it.
///
/// Everything runs off the main thread at utility priority: recognition on a full-size screenshot
/// takes tens to hundreds of milliseconds, which is a whole train of dropped frames if it lands
/// on the main queue while the panel is animating.
enum OCRService {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "ocrEnabled") as? Bool ?? true
    }

    /// Recognised text joined by newlines, or "" when the image holds none.
    static func recognizeText(in imageData: Data) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: recognizeTextSync(in: imageData))
            }
        }
    }

    /// Longest side of a tile, in pixels.
    ///
    /// Vision resizes what it is given to a working resolution of its own before it looks for
    /// text, so how large a letter is *in the picture* decides whether it is found — not how many
    /// pixels tall it is. Measured on the same four lines of text: in a 1600x1000 image, 14px text
    /// reads 4 lines of 4; in a 3200x2000 image the identical 14px text reads none, and nothing
    /// recovers it. `minimumTextHeight` does not: taking it from its 1/32 default down to the
    /// equivalent of 8px changed not one line, because the threshold was never what was rejecting
    /// them.
    ///
    /// Cutting a large picture into pieces and reading each one is what recovers them, because
    /// each piece is resized far less. Same 3200x2000 image, six tiles: 10px, 14px and 18px text
    /// all go from 0 of 4 lines to 4 of 4.
    ///
    /// 1200 leaves room for the overlap below to stay inside the 1600 long side that measured
    /// good.
    private static let tileSide = 1200

    /// How far tiles reach into their neighbours, as a fraction of a tile.
    ///
    /// A line of text sitting across a cut would otherwise be read as two half-height fragments,
    /// or missed. The duplicates this creates are removed by the line-level dedup in
    /// `recognizeTextSync`.
    private static let tileOverlap = 0.1

    /// A bound on the work, for the picture nobody expects — a full-page capture tens of thousands
    /// of pixels tall. Past this the image is read in one pass instead: small text in it will be
    /// missed, which is what would have happened anyway before tiling existed.
    private static let maxTiles = 24

    private static func recognizeTextSync(in imageData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return "" }

        let request = makeRequest()
        let regions = tiles(for: image)
        guard regions.count > 1 else { return lines(in: image, using: request).joined(separator: "\n") }

        // Deduplicated by line rather than merged geometrically: the text is only ever read back
        // by a substring search, so a line's position on the page buys nothing, and the overlap
        // guarantees repeats that would otherwise show up twice in a search preview.
        var seen: Set<String> = []
        var collected: [String] = []
        for region in regions {
            guard let tile = tileImage(image, region) else { continue }
            for line in lines(in: tile, using: request) where seen.insert(line).inserted {
                collected.append(line)
            }
        }
        return collected.joined(separator: "\n")
    }

    /// One tile, in memory of its own.
    ///
    /// `cropping(to:)` alone is not enough. What it returns still points into the parent's pixel
    /// buffer, and handing one to Vision crashed in `CIImage.initWithCGImage` — SIGBUS inside
    /// `memmove`, reading past the end of the parent's mapping. Drawing the crop into a fresh
    /// context gives the tile its own bytes, which is what the crash was about; the rect is also
    /// clamped to the picture first, because `CGRect.integral` rounds *outward* and so could
    /// name a rectangle larger than the image it came from.
    private static func tileImage(_ image: CGImage, _ region: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = region.intersection(bounds).integral.intersection(bounds)
        let width = Int(clamped.width), height = Int(clamped.height)
        guard width > 0, height > 0, let cropped = image.cropping(to: clamped) else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = preferredLanguages(for: request)
        return request
    }

    private static func lines(in image: CGImage, using request: VNRecognizeTextRequest) -> [String] {
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func tiles(for image: CGImage) -> [CGRect] {
        tiles(width: image.width, height: image.height)
    }

    /// The rectangles to read, top to bottom and left to right, or one rectangle when the picture
    /// is small enough to read whole.
    ///
    /// Takes the size rather than the picture so the geometry can be checked without allocating
    /// one — the case worth checking hardest is a 4000x40000 full-page capture, and building that
    /// bitmap to ask a question about arithmetic costs 640 MB.
    static func tiles(width: Int, height: Int) -> [CGRect] {
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        guard max(width, height) > tileSide else { return [whole] }

        let columns = max(1, Int(ceil(Double(width) / Double(tileSide))))
        let rows = max(1, Int(ceil(Double(height) / Double(tileSide))))
        guard columns * rows > 1, columns * rows <= maxTiles else { return [whole] }

        let tileWidth = Double(width) / Double(columns)
        let tileHeight = Double(height) / Double(rows)
        let padX = tileWidth * tileOverlap
        let padY = tileHeight * tileOverlap

        var regions: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = max(0, Double(column) * tileWidth - padX)
                let y = max(0, Double(row) * tileHeight - padY)
                let rect = CGRect(x: x, y: y,
                                  width: min(Double(width) - x, tileWidth + padX * 2),
                                  height: min(Double(height) - y, tileHeight + padY * 2))
                regions.append(rect.integral)
            }
        }
        return regions
    }

    /// The user's own languages, filtered down to what this Vision revision actually supports,
    /// with English as a fallback — asking for an unsupported language makes `perform` throw and
    /// returns nothing at all.
    private static func preferredLanguages(for request: VNRecognizeTextRequest) -> [String] {
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        guard !supported.isEmpty else { return [] }
        var wanted = Locale.preferredLanguages.compactMap { tag -> String? in
            supported.first { $0 == tag || $0.hasPrefix(tag.prefix(2) + "-") || $0 == String(tag.prefix(2)) }
        }
        if let english = supported.first(where: { $0.hasPrefix("en") }), !wanted.contains(english) {
            wanted.append(english)
        }
        return wanted.isEmpty ? [supported[0]] : wanted
    }

    /// Scans one item and records the result (including an empty one, which marks it scanned).
    static func scan(itemID: UUID, imageData: Data) {
        guard isEnabled else { return }
        Task.detached(priority: .utility) {
            let text = await recognizeText(in: imageData)
            await record(text, for: itemID)
        }
    }

    /// Writes a result, but never while the panel is on screen.
    ///
    /// Every store mutation with the panel visible costs a full SwiftUI re-layout, and OCR
    /// finishing mid-open would spend it right on top of the open animation. Recognition itself
    /// runs on a background queue, so only this hand-off has to wait.
    @MainActor
    private static func record(_ text: String, for id: UUID) async {
        let text = storable(text, patterns: ExclusionRules.storedPatterns())
        var waited = 0
        while !ClipboardStore.shared.publishingSuppressed, waited < 60 {
            waited += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        ClipboardStore.shared.setOCRText(text, for: id)
    }

    /// What may be written for a picture, given the never-store patterns.
    ///
    /// The capture path checks those patterns against an item's text and its paths and returns
    /// before storing anything that matches — but an image has no text at that point, so it takes
    /// the fast path out and is never asked. Recognition is where the text finally exists, and
    /// without this an API key photographed rather than copied was written to the history and made
    /// searchable by the very string the user had asked never to be stored.
    ///
    /// An empty result rather than no result: `nil` means "not scanned yet", so returning that
    /// would put the item back in the queue and read it again on every launch. The picture itself
    /// is left alone — the user copied it deliberately, and it is the text that was asked about.
    static func storable(_ text: String, patterns: [String]) -> String {
        guard !patterns.isEmpty, !text.isEmpty else { return text }
        return ExclusionRules.shouldExclude(text, patterns: patterns) ? "" : text
    }

    // MARK: - Backfill

    private static var backfillRunning = false
    /// A bound on the launch-time sweep: images copied long ago are the least likely to be
    /// searched for, and an unbounded sweep on a 3000-item history would run for minutes.
    private static let backfillLimit = 400

    /// Scans images already in the history that predate OCR (or were captured while it was off).
    ///
    /// Sequential and paused while the panel is on screen: each result mutates the store, and a
    /// store mutation with the panel visible costs a full SwiftUI re-layout.
    @MainActor
    static func startBackfill() {
        guard isEnabled, !backfillRunning else { return }
        backfillRunning = true
        Task { @MainActor in
            defer { backfillRunning = false }
            var scanned = 0
            var waits = 0
            while scanned < backfillLimit {
                guard isEnabled else { return }
                // Only work while nothing is on screen; the panel sets this when it hides.
                guard ClipboardStore.shared.publishingSuppressed else {
                    // Give up after ~5 minutes of the panel staying open rather than waking
                    // every two seconds forever; the next launch picks the sweep back up.
                    waits += 1
                    guard waits < 150 else { return }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }
                waits = 0
                guard let next = ClipboardStore.shared.itemsAwaitingOCR().first else { return }
                // The thumbnail, deliberately — the one reader that does *not* want the original.
                //
                // It looks like it should: the compression loop drops to quality 0.10 before it
                // scales, and large screenshots have the smallest text. Measured, it is the other
                // way round: on a 3024x1890 screenshot with 24pt text the original scored 3 lines
                // of 4 and the thumbnail 4 of 4, at 777ms against 125ms.
                //
                // Same cause as `tileSide`: Vision resizes its input, so a picture with fewer
                // pixels has *larger* text once it gets there. Tiling now recovers the small text
                // in either, which leaves cost as the only difference — and the original is four
                // times the tiles.
                let data = next.imageData ?? ClipboardStore.shared.imageBytes(for: next.id)
                guard let data else {
                    // No pixels on disk any more — mark it scanned so we don't spin on it.
                    ClipboardStore.shared.setOCRText("", for: next.id)
                    continue
                }
                let text = await recognizeText(in: data)
                // Re-checked through `record`: the panel may well have opened during the scan.
                await record(text, for: next.id)
                scanned += 1
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }
}
