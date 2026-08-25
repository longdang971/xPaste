import AppKit

/// Moves a history written as JSON files into the database, once.
///
/// Two formats have to be dealt with, because there were two: a single `history.json` holding an
/// array, and then a file per item under `items/`. Both are read here rather than chained through
/// each other — a machine that skipped a release should not have to migrate twice to arrive at the
/// same place.
///
/// Pictures are left exactly where they are. They were already files beside the metadata rather
/// than inside it, `ClipboardStore` still reads them from there, and rewriting a thousand JPEGs to
/// change nothing about them would be the slowest part of a launch that has no reason to be slow.
enum LegacyJSONImport {

    /// Reads whatever old history is in `dir` into `database`, then moves the old files aside.
    ///
    /// Moved rather than deleted. This runs once, over everything the user has, and it is the only
    /// step in the app that turns one representation of their history into another — so the
    /// evidence that it went well should still be there afterwards. `items.migrated` is also what
    /// stops it running twice, because the import only ever looks at `items`.
    ///
    /// It happens only after the import has been flushed to the store, so an interruption leaves
    /// the old files where they were and the next launch tries again — importing an item twice is
    /// harmless (the id is the same row), losing one is not.
    static func run(from dir: URL, into database: ClipboardDatabase) {
        let itemsDir = dir.appendingPathComponent("items", isDirectory: true)
        let singleFile = dir.appendingPathComponent("history.json")

        var imported = 0
        imported += importSingleFile(at: singleFile, into: database)
        imported += importPerItemFiles(in: itemsDir, into: database)
        guard imported > 0 else { return }

        database.flush()
        let fm = FileManager.default
        if fm.fileExists(atPath: singleFile.path) {
            try? fm.removeItem(at: dir.appendingPathComponent("history.json.migrated"))
            try? fm.moveItem(at: singleFile, to: dir.appendingPathComponent("history.json.migrated"))
        }
        if fm.fileExists(atPath: itemsDir.path) {
            let aside = dir.appendingPathComponent("items.migrated", isDirectory: true)
            try? fm.removeItem(at: aside)
            try? fm.moveItem(at: itemsDir, to: aside)
        }
    }

    // MARK: - The two formats

    private static func importSingleFile(at url: URL, into database: ClipboardDatabase) -> Int {
        guard let data = try? Data(contentsOf: url),
              let legacy = try? JSONDecoder().decode([LegacyItem].self, from: data)
        else { return 0 }
        for item in legacy { store(item, into: database) }
        return legacy.count
    }

    private static func importPerItemFiles(in dir: URL, into database: ClipboardDatabase) -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return 0 }

        var count = 0
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let legacy = try? JSONDecoder().decode(LegacyItem.self, from: data)
            else { continue }
            store(legacy, into: database)
            count += 1
        }
        return count
    }

    // MARK: - Building an item out of what the old format had

    private static func store(_ legacy: LegacyItem, into database: ClipboardDatabase) {
        let item = ClipboardItem(
            id: legacy.id,
            type: legacy.type,
            text: legacy.text.map { String($0.prefix(ItemEntity.previewCharLimit)) },
            imageData: nil,
            imageSize: legacy.imageSize,
            imageHash: legacy.imageHash,
            fileURLs: legacy.fileURLs,
            timestamp: legacy.timestamp,
            isPinned: legacy.isPinned,
            label: legacy.label,
            sourceAppBundleID: legacy.sourceAppBundleID,
            ocrText: legacy.ocrText,
            richData: legacy.richData,
            richType: legacy.richType,
            revision: legacy.revision,
            hasRichText: legacy.richData != nil,
            fullTextLength: legacy.text?.count ?? 0,
            // From the full text, which the old file still has — the item above is built from a
            // prefix of it, and a key taken from that prefix would not match the one every later
            // copy of the same text produces.
            checksum: ClipboardItem.makeChecksum(type: legacy.type, id: legacy.id,
                                                 text: legacy.text,
                                                 imageHash: legacy.imageHash,
                                                 fileURLs: legacy.fileURLs)
        )

        database.upsert(item, payload: payload(for: legacy))
    }

    /// The best payload the old format can support.
    ///
    /// It kept one formatted representation and the plain string, so that is exactly what comes
    /// out — an imported item is no more faithful than it was, and pretending otherwise by
    /// inventing representations would be worse than the gap. Items copied after the migration get
    /// everything the source offered; these keep what they had.
    private static func payload(for legacy: LegacyItem) -> PasteboardPayload? {
        switch legacy.type {
        case .text, .url, .color:
            guard let text = legacy.text else { return nil }
            var payload = PasteboardPayload.plainText(text)
            if let data = legacy.richData, !data.isEmpty, let type = legacy.richType {
                payload.items[0].types.insert(type, at: 0)
                payload.items[0].dataByType[type] = data
            }
            return payload

        case .file, .folder:
            guard let urls = legacy.fileURLs, !urls.isEmpty else { return nil }
            let joined = urls.map(\.path).joined(separator: "\n")
            var payload = PasteboardPayload.plainText(joined)
            if let first = urls.first?.absoluteString.data(using: .utf8) {
                let type = "public.file-url"
                payload.items[0].types.insert(type, at: 0)
                payload.items[0].dataByType[type] = first
            }
            return payload

        case .image:
            // The picture is a file beside the database and `ClipboardStore` reads it from there.
            // Copying it into a payload would store the same bytes twice for no gain: it is the
            // compressed capture either way, because the original was never kept.
            return nil
        }
    }

    /// The on-disk shape of an item before the database, decoded on its own terms.
    ///
    /// Not `ClipboardItem` itself: that type now carries fields the old format never had, and
    /// decoding straight into it would tie the format that must stay readable forever to a type
    /// that is expected to keep changing.
    private struct LegacyItem: Decodable {
        let id: UUID
        let type: ClipboardContentType
        let text: String?
        let imageSize: Int?
        let imageHash: String?
        let fileURLs: [URL]?
        let timestamp: Date
        let isPinned: Bool
        let label: String?
        let sourceAppBundleID: String?
        let ocrText: String?
        let richData: Data?
        let richType: String?
        let revision: Int?

        enum CodingKeys: String, CodingKey {
            case id, type, text, imageSize, imageHash, fileURLs, timestamp
            case isPinned, label, sourceAppBundleID, ocrText, richData, richType, revision
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            type = try c.decode(ClipboardContentType.self, forKey: .type)
            timestamp = try c.decode(Date.self, forKey: .timestamp)
            // Everything below arrived in the format at different times, so every one of them is
            // optional-with-a-default rather than optional: a file written before a field existed
            // must still decode, and `decodeIfPresent` on a missing key is exactly that.
            text = try c.decodeIfPresent(String.self, forKey: .text)
            imageSize = try c.decodeIfPresent(Int.self, forKey: .imageSize)
            imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
            fileURLs = try c.decodeIfPresent([URL].self, forKey: .fileURLs)
            isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
            label = try c.decodeIfPresent(String.self, forKey: .label)
            sourceAppBundleID = try c.decodeIfPresent(String.self, forKey: .sourceAppBundleID)
            ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
            richData = try c.decodeIfPresent(Data.self, forKey: .richData)
            richType = try c.decodeIfPresent(String.self, forKey: .richType)
            revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        }
    }
}
