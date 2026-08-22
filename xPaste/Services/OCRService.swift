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

    private static func recognizeTextSync(in imageData: Data) -> String {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return "" }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = preferredLanguages(for: request)

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
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
        var waited = 0
        while !ClipboardStore.shared.publishingSuppressed, waited < 60 {
            waited += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        ClipboardStore.shared.setOCRText(text, for: id)
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
