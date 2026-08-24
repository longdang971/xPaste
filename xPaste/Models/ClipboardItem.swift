import Foundation
import AppKit

enum ClipboardContentType: String, Codable {
    case text, url, color, image, file, folder
}

struct ClipboardItem: Identifiable, Codable {
    let id: UUID
    var type: ClipboardContentType
    var text: String?
    var imageData: Data?
    var imageSize: Int?
    var imageHash: String?
    var fileURLs: [URL]?
    var timestamp: Date
    var isPinned: Bool
    /// User-given name. Shown instead of the generic card title and searched like the content,
    /// which is what turns a pinned item into a snippet you can find by name.
    var label: String?
    var sourceAppBundleID: String?
    /// Text recognised inside an image by `OCRService`, so screenshots are searchable.
    /// `nil` means "not scanned yet"; an empty string means "scanned, found nothing".
    var ocrText: String?
    /// Formatted representation (RTF or HTML) so a paste can preserve styling.
    var richData: Data?
    /// Raw pasteboard type of `richData` (e.g. "public.rtf" or "public.html").
    var richType: String?
    /// Bumped every time the content is edited.
    ///
    /// Six caches key on this item's `id`, which does not change when its content does. Purging
    /// them covers five; the sixth is the card's own `@State`, which only refreshes when its
    /// `.task` re-runs — and the task is keyed on values that an edit leaves alone. Carrying the
    /// revision in that key is what makes the card notice. See `ClipboardStore.updateContent`.
    ///
    /// Optional because `Codable` here is synthesised: a non-optional new property fails to decode
    /// every item already on disk. `contentRevision` is what callers should read.
    var revision: Int?

    /// The revision as a number, for callers that do not care that it was once absent.
    var contentRevision: Int { revision ?? 0 }

    enum CodingKeys: String, CodingKey {
        case id, type, text, imageSize, imageHash, fileURLs, timestamp, isPinned, label, sourceAppBundleID, ocrText, richData, richType, revision
    }

    init(
        id: UUID = UUID(),
        type: ClipboardContentType,
        text: String? = nil,
        imageData: Data? = nil,
        imageSize: Int? = nil,
        imageHash: String? = nil,
        fileURLs: [URL]? = nil,
        timestamp: Date = Date(),
        isPinned: Bool = false,
        label: String? = nil,
        sourceAppBundleID: String? = nil,
        ocrText: String? = nil,
        richData: Data? = nil,
        richType: String? = nil,
        revision: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.imageData = imageData
        self.imageSize = imageSize ?? imageData?.count
        self.imageHash = imageHash ?? imageData.map { Self.makeHash($0) }
        self.fileURLs = fileURLs
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.label = label
        self.sourceAppBundleID = sourceAppBundleID
        self.ocrText = ocrText
        self.richData = richData
        self.richType = richType
        self.revision = revision
    }

    var displayText: String {
        switch type {
        case .text, .url, .color: return text ?? ""
        case .image: return label ?? "Image"
        case .file: return fileURLs?.map(\.lastPathComponent).joined(separator: ", ") ?? "File"
        case .folder: return fileURLs?.map(\.lastPathComponent).joined(separator: ", ") ?? "Folder"
        }
    }

    var previewImage: NSImage? {
        guard let data = imageData else { return nil }
        return NSImage(data: data)
    }

    static func from(pasteboard: NSPasteboard) -> ClipboardItem? {
        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !fileURLs.isEmpty {
            // Treat the selection as a folder only when every item is a directory;
            // any regular file in the mix keeps it classified as a plain file.
            let type: ClipboardContentType = allDirectories(fileURLs) ? .folder : .file
            return ClipboardItem(type: type, fileURLs: fileURLs)
        }

        if let types = pasteboard.types,
           types.contains(where: { $0 == .tiff || $0 == .png }),
           let image = NSImage(pasteboard: pasteboard),
           let compressed = image.compressedData(maxBytes: 1_000_000) {
            return ClipboardItem(type: .image, imageData: compressed)
        }

        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let (richData, richType) = captureRich(from: pasteboard)
            return ClipboardItem(type: contentType(for: string), text: string,
                                 richData: richData, richType: richType)
        }

        return nil
    }

    /// Whether a piece of text is a colour, a link, or plain text.
    ///
    /// Shared with editing rather than left inline here: an edit that turns prose into a URL (or a
    /// colour back into prose) has to reach the same verdict capture would, or the same string ends
    /// up as one kind of card one way and another the other.
    ///
    /// Only `http` and `https` count for links. Those are the schemes a link preview can fetch; a
    /// `mailto:` card promoted to a Link would sit waiting for a page that is never coming.
    static func contentType(for text: String) -> ClipboardContentType {
        // Asked before the URL check for the reader's sake rather than for correctness — nothing
        // that parses as a colour also parses as an http URL. `ColorParser` decides; this must not
        // grow a second opinion about what a colour is.
        if ColorParser.isColor(text) { return .color }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            return .text
        }
        return .url
    }

    /// True only when every URL points at a plain directory. Packages/bundles
    /// (`.app`, `.bundle`, …) are directories on disk but behave like single files
    /// to the user, so they count as files, not folders.
    private static func allDirectories(_ urls: [URL]) -> Bool {
        urls.allSatisfy { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true
        }
    }

    /// Grabs a formatted representation (RTF preferred, then HTML) if the source provided one.
    private static func captureRich(from pb: NSPasteboard) -> (Data?, String?) {
        if let d = pb.data(forType: .rtf), !d.isEmpty {
            return (d, NSPasteboard.PasteboardType.rtf.rawValue)
        }
        if let d = pb.data(forType: .html), !d.isEmpty {
            return (d, NSPasteboard.PasteboardType.html.rawValue)
        }
        return (nil, nil)
    }

    func copyToPasteboard() {
        write(to: .general)
        ClipboardMonitor.shared.markNextChangeAsOwn()
    }

    /// Writes this item's payload to `pb`. Extracted from `copyToPasteboard()` so the
    /// pasteboard contents can be verified in tests without touching `NSPasteboard.general`.
    func write(to pb: NSPasteboard) {
        pb.clearContents()
        switch type {
        case .text, .url, .color:
            // Write the formatted representation first (if any) so rich editors keep styling,
            // plus a plain-string fallback for everything else. A colour never has `richData` — see
            // `ItemEdit.keepsFormatting` — so this is always the plain-string path for `.color`.
            if let richData, let richType, !richData.isEmpty {
                pb.setData(richData, forType: NSPasteboard.PasteboardType(richType))
            }
            if let text { pb.setString(text, forType: .string) }
        case .image:
            let data = imageData ?? ClipboardStore.shared.imageBytes(for: id)
            if let data, let image = NSImage(data: data) {
                pb.writeObjects([image])
            }
        case .file, .folder:
            // Write the file reference so Finder (and file-aware apps) paste the actual
            // file/folder, plus the path(s) as plain text so text fields receive the path
            // instead of a file attachment. One path per line for multi-item selections.
            if let urls = fileURLs, !urls.isEmpty {
                pb.writeObjects(urls as [NSURL])
                pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
        }
    }

    static func makeHash(_ data: Data) -> String {
        let count = data.count
        let prefix = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        let suffix = data.suffix(16).map { String(format: "%02x", $0) }.joined()
        return "\(count)-\(prefix)-\(suffix)"
    }
}
