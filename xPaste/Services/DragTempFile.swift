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
        guard let bytes = item.imageData ?? ClipboardStore.shared.imageBytes(for: item.id),
              !bytes.isEmpty
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
        guard let directory = directory(for: item.id) else { return nil }
        let target = directory.appendingPathComponent("\(name).\(ext)")

        // Same item dragged twice in a session: the file is already there and identical.
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard (try? bytes.write(to: target, options: .atomic)) != nil else { return nil }
        return target
    }

    /// Cleared once per launch rather than per drag: a drop copies the file while the session is
    /// still running, so removing anything mid-session risks pulling it out from under a drop that
    /// has not finished. A session's worth of dragged pictures is a handful of megabytes, and the
    /// system clears the directory itself between launches anyway.
    static func clearLeftovers() {
        try? FileManager.default.removeItem(at: root())
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
