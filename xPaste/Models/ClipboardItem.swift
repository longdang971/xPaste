import Foundation
import AppKit

enum ClipboardContentType: String, Codable {
    case text, url, image, file, folder
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

    enum CodingKeys: String, CodingKey {
        case id, type, text, imageSize, imageHash, fileURLs, timestamp, isPinned, label, sourceAppBundleID, ocrText, richData, richType
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
        richType: String? = nil
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
    }

    var displayText: String {
        switch type {
        case .text, .url: return text ?? ""
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
            if let url = URL(string: trimmed),
               url.scheme == "http" || url.scheme == "https" {
                return ClipboardItem(type: .url, text: string, richData: richData, richType: richType)
            }
            return ClipboardItem(type: .text, text: string, richData: richData, richType: richType)
        }

        return nil
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
        case .text, .url:
            // Write the formatted representation first (if any) so rich editors keep styling,
            // plus a plain-string fallback for everything else.
            if let richData, let richType, !richData.isEmpty {
                pb.setData(richData, forType: NSPasteboard.PasteboardType(richType))
            }
            if let text { pb.setString(text, forType: .string) }
        case .image:
            let data = imageData ?? ClipboardStore.shared.imageURL(for: id).flatMap { try? Data(contentsOf: $0) }
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
