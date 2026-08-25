import AppKit

/// The copy of an image a drag hands to Finder.
///
/// The stored file is named `<uuid>.jpg` whatever is actually in it — `compressedData` writes PNG
/// for anything using its alpha channel, and the name was settled before the format was. Dropping
/// that file gave a picture called `9F3A…-…jpg` that was really a PNG: an unhelpful name and a
/// misleading extension, in the one place the user sees the file rather than the card.
///
/// So a drag copies the bytes to a temporary file named the way `SaveFormat` would name them, with
/// the extension those bytes actually are. The drop copies from there and the original is untouched.
enum DragTempFile {

    /// A file for `item`'s picture, or nil when there are no bytes to write.
    static func url(for item: ClipboardItem) -> URL? {
        guard item.type == .image else { return nil }
        // The original: what Finder receives should be what was copied, not xPaste's re-encoding
        // of it. `recognisedImageExtension` below names the file from the bytes either way.
        guard let bytes = ClipboardStore.shared.originalImageBytes(for: item), !bytes.isEmpty
        else { return nil }

        // Only bytes that name themselves. Writing a `.png` holding something else would be the
        // same lie in a new place; the caller falls back to dragging the bitmap.
        guard let ext = SaveFormat.recognisedImageExtension(for: bytes) else { return nil }
        let name = SaveFormat.baseName(for: item)
        // A folder per item, so the file keeps the clean name while the path stays unique.
        //
        // Names collide readily: two items the user called "logo", or two screenshots taken in the
        // same second, both resolve to the same file name. Sharing a path meant the second drag
        // found the first item's file already there, kept it, and handed Finder the wrong picture
        // without a word.
        pruneIfNeeded(keeping: item.id)
        guard let directory = directory(for: item.id) else { return nil }
        let target = directory.appendingPathComponent("\(name).\(ext)")

        // Same item dragged twice in a session: the file is already there and identical.
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard (try? bytes.write(to: target, options: .atomic)) != nil else { return nil }
        return target
    }

    /// Cleared once per launch: a drop copies the file while the session is still running, so
    /// removing anything mid-session risks pulling it out from under a drop that has not finished.
    static func clearLeftovers() {
        try? FileManager.default.removeItem(at: root())
    }

    /// The most this directory may hold before old drags are pruned.
    ///
    /// It used to be left to grow for the whole session on the grounds that "a session's worth of
    /// dragged pictures is a handful of megabytes". That stopped being true when a drag started
    /// writing the picture as it was copied rather than the card's re-encoding of it: an ordinary
    /// screen capture is a 17 MB TIFF against a 780 KB JPEG, so twenty drags is well over a
    /// third of a gigabyte sitting in the temporary directory until the next launch.
    private static let byteCap = 256 * 1024 * 1024

    /// Nothing this recent is touched, whatever the total.
    ///
    /// A drop copies out of these files itself, and the copy runs after the drag has ended — so a
    /// folder written moments ago may still be being read. Only drags old enough that any drop has
    /// long since finished are candidates.
    private static let minimumAge: TimeInterval = 60

    /// Drops the oldest drags once the directory is over `byteCap`.
    ///
    /// Called before a new file is written, so the cap is enforced at the one moment the directory
    /// grows. `keeping` is the drag being written now, which is never a candidate however the
    /// arithmetic comes out.
    private static func pruneIfNeeded(keeping current: UUID) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root(), includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return }

        var candidates: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        let now = Date()
        for entry in entries {
            let size = directorySize(entry)
            total += size
            guard entry.lastPathComponent != current.uuidString else { continue }
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard now.timeIntervalSince(date) >= minimumAge else { continue }
            candidates.append((entry, date, size))
        }
        guard total > byteCap else { return }

        for candidate in candidates.sorted(by: { $0.date < $1.date }) {
            try? fm.removeItem(at: candidate.url)
            total -= candidate.size
            if total <= byteCap { return }
        }
    }

    private static func directorySize(_ url: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys) else { return 0 }
        return files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
    }

    private static func root() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("xPaste-drag", isDirectory: true)
    }

    private static func directory(for id: UUID) -> URL? {
        let url = root().appendingPathComponent(id.uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)) != nil else { return nil }
        return url
    }
}
