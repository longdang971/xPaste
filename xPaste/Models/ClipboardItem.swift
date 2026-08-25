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

    /// Every representation the source app offered, or nil for an item that is not carrying them
    /// right now — which is every item restored from the store.
    ///
    /// Transient in the same way `imageData` is: it exists between capture and the write that
    /// persists it, and `ClipboardStore.add` drops it as soon as that write is queued. Readers go
    /// to `ClipboardStore.payload(for:)`, which is the one place that has them.
    var payload: PasteboardPayload?

    /// Whether the stored payload carries a formatted representation.
    ///
    /// Separate from `richData != nil` because a restored item has the flag and not the bytes —
    /// which is the point of the split. A card asks this before deciding to load anything; without
    /// it, finding out which items have styling would mean faulting in every payload in the
    /// history.
    var hasRichText: Bool = false

    /// Length of the full text, which `text` may be a prefix of.
    ///
    /// See `ItemEntity.previewText`: what the store keeps hot is capped, because a card and a
    /// search hit can only ever show the first few hundred characters and the alternative is a
    /// pasted log file resident for as long as the app runs. Anything that pastes, saves, drags or
    /// edits an item takes the full text from the payload instead — see `ClipboardStore.hydrated`.
    var fullTextLength: Int = 0

    /// See `makeChecksum`. Assigned by every initialiser; never derived at the point of use.
    var checksum: String = ""

    /// The revision as a number, for callers that do not care that it was once absent.
    var contentRevision: Int { revision ?? 0 }

    /// Whether this item has formatted bytes anywhere — in hand, or in the store.
    ///
    /// The accessor rather than `hasRichText` is what callers should ask, so an item built in
    /// memory (which has the bytes and not the flag) and one restored from the store (which has
    /// the flag and not the bytes) answer the same.
    var carriesRichText: Bool { hasRichText || richData != nil }

    /// Length of the full text, however much of it this item is holding.
    var textLength: Int { max(fullTextLength, text?.count ?? 0) }

    /// Whether `text` is a prefix of something longer. True only for the rare item whose text ran
    /// past `ItemEntity.previewCharLimit`.
    var isTextTruncated: Bool { textLength > (text?.count ?? 0) }

    /// The dedup key for an item's content, computed from the whole of it.
    ///
    /// Stored rather than computed, and this is the reason: `text` is a prefix once the content
    /// runs past `ItemEntity.previewCharLimit`, so a key derived on the way back out of the store
    /// would be derived from less than the key written on the way in. The two would not match, and
    /// dedup would stop recognising long texts across a relaunch — quietly, and only for the items
    /// most worth recognising.
    /// `id` is used only when the content that would identify the item is not there — an image
    /// with no bytes and no hash, a file item with no paths. Without it every such item hashes to
    /// the same key and they deduplicate onto one another, which is a way to lose one by copying
    /// another. Falling back to the id says "this one is nothing else", which is the truth.
    static func makeChecksum(type: ClipboardContentType,
                             id: UUID,
                             text: String?,
                             imageHash: String?,
                             fileURLs: [URL]?) -> String {
        switch type {
        case .text, .url, .color:
            guard let text, !text.isEmpty else { return "\(type.rawValue)!\(id.uuidString)" }
            return "\(type.rawValue):\(text)"
        case .image:
            guard let imageHash, !imageHash.isEmpty else { return "image!\(id.uuidString)" }
            return "image:\(imageHash)"
        case .file, .folder:
            guard let fileURLs, !fileURLs.isEmpty else { return "\(type.rawValue)!\(id.uuidString)" }
            return "\(type.rawValue):\(fileURLs.map(\.path).joined(separator: "\u{1}"))"
        }
    }

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
        revision: Int? = nil,
        hasRichText: Bool? = nil,
        fullTextLength: Int? = nil,
        checksum: String? = nil
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
        self.hasRichText = hasRichText ?? (richData != nil)
        self.fullTextLength = fullTextLength ?? (text?.count ?? 0)
        // Handed in when it is already known — which is every item coming back out of the store,
        // where the stored key is the one that was written from the full content.
        self.checksum = checksum ?? Self.makeChecksum(type: type, id: self.id, text: text,
                                                      imageHash: self.imageHash, fileURLs: fileURLs)
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
        // Read once, up front, and attach to whichever item is built below. Every branch wants it,
        // and reading the pasteboard twice is reading it at two different moments: the contents can
        // change underneath a second pass, and then the payload would describe something other
        // than the item it is stored against.
        let payload = PasteboardPayload.capture(from: pasteboard)

        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !fileURLs.isEmpty {
            // Treat the selection as a folder only when every item is a directory;
            // any regular file in the mix keeps it classified as a plain file.
            let type: ClipboardContentType = allDirectories(fileURLs) ? .folder : .file
            var item = ClipboardItem(type: type, fileURLs: fileURLs)
            item.payload = payload
            return item
        }

        if let types = pasteboard.types,
           types.contains(where: { $0 == .tiff || $0 == .png }),
           let image = NSImage(pasteboard: pasteboard),
           let compressed = image.compressedData(maxBytes: 1_000_000) {
            var item = ClipboardItem(type: .image, imageData: compressed)
            item.payload = payload
            return item
        }

        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Decide the type before capturing so a colour never gets the chance to carry a rich
            // representation in the first place — a seven-character hex code has no business
            // hauling an RTF document along with it.
            let type = contentType(for: string)
            let (richData, richType) = type == .color ? (nil, nil) : captureRich(from: pasteboard)
            var item = ClipboardItem(type: type, text: string,
                                     richData: richData, richType: richType)
            item.payload = type == .color ? PasteboardPayload.plainText(string) : payload
            return item
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

        // The stored payload first, when there is one: it is every representation the source app
        // offered, in the order it offered them, so a receiving app picks what it would have picked
        // had it been handed the original copy. The per-type branches below are the fallback for
        // items that predate the payload — anything restored from the JSON history — and for items
        // whose payload was refused at capture for being over the size cap.
        if let payload = payload ?? ClipboardStore.shared.payload(for: id), !payload.isEmpty {
            payload.write(to: pb)
            return
        }

        switch type {
        case .text, .url, .color:
            // Write the formatted representation first (if any) so rich editors keep styling,
            // plus a plain-string fallback for everything else. A colour never has `richData`:
            // `from(pasteboard:)` skips the capture for `.color`, and `ItemEdit.keepsFormatting`
            // keeps an edit from adding it back — so this is always the plain-string path for `.color`.
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
