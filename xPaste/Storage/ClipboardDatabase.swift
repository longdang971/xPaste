import CoreData
import Foundation

/// The persistence layer behind `ClipboardStore`.
///
/// `ClipboardStore` keeps the history in an array and publishes from it, and every piece of
/// measured work in that class — suppressed publishing, cached filtering, bounded image decoding —
/// depends on that array staying exactly what it is. So this is not a replacement for it: the
/// array is still the thing the panel reads, and this is where it is loaded from and written back
/// to. What changed is what a row costs, not who owns it.
final class ClipboardDatabase {

    private let container: NSPersistentContainer

    /// Writes go here, reads at launch go through `container.viewContext`.
    ///
    /// One background context, used serially through `perform`, gives the same ordering guarantee
    /// the serial `DispatchQueue` gave before it — a save queued after a delete runs after it — and
    /// `performAndWait` behind the backlog is what `flush()` is.
    private let writeContext: NSManagedObjectContext

    /// Where the store file lives, or nil for an in-memory store.
    let storeURL: URL?

    /// Opens (or creates) the store under `storageDir`. A nil directory gives an in-memory store,
    /// which is what the tests use and what a store with nowhere to write falls back to.
    init?(storageDir: URL?) {
        container = NSPersistentContainer(name: "ClipboardHistory",
                                          managedObjectModel: ClipboardSchema.model)

        let description: NSPersistentStoreDescription
        if let storageDir {
            try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            let url = storageDir.appendingPathComponent("ClipboardHistory.sqlite")
            description = NSPersistentStoreDescription(url: url)
            description.type = NSSQLiteStoreType
            // A clipboard history is written on nearly every copy and read in one burst at launch.
            // WAL is what keeps a write from blocking that read.
            description.setValue("WAL" as NSString, forPragmaNamed: "journal_mode")
            storeURL = url
        } else {
            description = NSPersistentStoreDescription()
            description.type = NSInMemoryStoreType
            storeURL = nil
        }
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var failure: Error?
        container.loadPersistentStores { _, error in failure = error }
        if failure != nil { return nil }

        container.viewContext.automaticallyMergesChangesFromParent = true
        // Last write wins on a property-by-property basis. The only writer is this app, and the
        // one place two writes can meet is a metadata update racing the trim that removes the same
        // row — where the delete has to win, and does, because the row is gone.
        container.viewContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)

        writeContext = container.newBackgroundContext()
        writeContext.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        writeContext.undoManager = nil
    }

    // MARK: - Loading

    /// The whole history, hot half only.
    ///
    /// `includesPropertyValues` stays on — these *are* the property values the panel draws — but
    /// the payload relationship is deliberately not prefetched: faulting it here would undo the
    /// split this schema exists for.
    func loadItems() -> [ClipboardItem] {
        let request = NSFetchRequest<ItemEntity>(entityName: "ItemEntity")
        request.sortDescriptors = [
            NSSortDescriptor(key: "isPinned", ascending: false),
            NSSortDescriptor(key: "timestamp", ascending: false),
        ]
        request.relationshipKeyPathsForPrefetching = ["sourceApplication"]
        let context = container.viewContext
        var loaded: [ClipboardItem] = []
        context.performAndWait {
            guard let rows = try? context.fetch(request) else { return }
            loaded = rows.compactMap(ClipboardItem.init(row:))
        }
        return loaded
    }

    /// The stored payload for an item, faulted in on demand.
    ///
    /// Synchronous, and behind `flush()`, for the same reason `imageBytes(for:)` is: this is the
    /// only copy of the bytes, and a reader arriving before the write queue has drained would
    /// conclude the item had no payload and paste nothing.
    func payload(for id: UUID) -> PasteboardPayload? {
        flush()
        var result: PasteboardPayload?
        let context = container.viewContext
        context.performAndWait {
            guard let row = Self.item(id: id, in: context),
                  let bytes = row.data?.rawPasteboardItems
            else { return }
            result = PasteboardPayload(decoding: bytes)
        }
        return result
    }

    // MARK: - Writing

    /// Inserts an item, or updates the one already carrying its id.
    ///
    /// `payload` is optional so a metadata-only change — a pin, a rename, an OCR result — does not
    /// have to carry the bytes it is not touching. Passing nil leaves whatever payload the row
    /// already has; there is no way to spell "remove the payload" because nothing wants to.
    func upsert(_ item: ClipboardItem, payload: PasteboardPayload?) {
        let snapshot = ItemSnapshot(item: item)
        let encoded = payload.flatMap { try? $0.encoded() }
        writeContext.perform { [writeContext] in
            let row = Self.item(id: snapshot.id, in: writeContext)
                ?? ItemEntity(context: writeContext)
            snapshot.apply(to: row, in: writeContext)

            if let encoded {
                let payloadRow = row.data ?? ItemDataEntity(context: writeContext)
                payloadRow.rawPasteboardItems = encoded
                row.data = payloadRow
                row.payloadBytes = Int64(encoded.count)
            }
            try? writeContext.save()
        }
    }

    func delete(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        writeContext.perform { [writeContext] in
            let request = NSFetchRequest<ItemEntity>(entityName: "ItemEntity")
            request.predicate = NSPredicate(format: "id IN %@", ids)
            guard let rows = try? writeContext.fetch(request) else { return }
            // Fetched and deleted one at a time rather than by `NSBatchDeleteRequest`: a batch
            // delete goes straight to SQL, which means the cascade to `ItemDataEntity` never runs
            // and every deleted item leaves its payload — and its external blob file — behind.
            rows.forEach(writeContext.delete)
            try? writeContext.save()
        }
    }

    func deleteAll() {
        writeContext.perform { [writeContext] in
            let request = NSFetchRequest<ItemEntity>(entityName: "ItemEntity")
            guard let rows = try? writeContext.fetch(request) else { return }
            rows.forEach(writeContext.delete)
            try? writeContext.save()
        }
    }

    /// Waits for every queued write to reach the store.
    ///
    /// The context is serial, so an empty block behind the backlog returns only once the backlog
    /// has gone — the same guarantee, and the same reason, as the `saveQueue.sync {}` this replaced.
    func flush() {
        writeContext.performAndWait {}
    }

    // MARK: - Migration

    /// Rewrites dedup keys written before the content was hashed.
    ///
    /// Without it the upgrade is silent and wrong in one direction only: every row already in the
    /// store keeps a key in the old shape, nothing a newly copied item computes can match it, and
    /// what the user sees is that copying something they already have makes a second card.
    ///
    /// Text, colour, url and file keys carry their own content — that was the problem with them —
    /// so they convert from the key alone, without faulting a single payload. An image key does
    /// not, but the picture it was taken from is a small JPEG sitting beside the store, so that is
    /// read instead; a row whose picture has gone is left as it is, since nothing can say what it
    /// was. Both cost far less than the alternative, which is faulting in every payload in the
    /// history at launch — the one thing this schema is shaped to avoid.
    ///
    /// Keyed off the separator, so running it again does nothing. See `ClipboardItem.digestMark`.
    @discardableResult
    func migrateLegacyChecksums(imagesDir: URL?) -> Int {
        var rewritten = 0
        writeContext.performAndWait { [writeContext] in
            let request = NSFetchRequest<ItemEntity>(entityName: "ItemEntity")
            request.predicate = NSPredicate(format: "checksum CONTAINS %@",
                                            String(ClipboardItem.legacyMark))
            guard let rows = try? writeContext.fetch(request), !rows.isEmpty else { return }
            for row in rows {
                guard let key = Self.rehashedKey(for: row, imagesDir: imagesDir) else { continue }
                row.checksum = key.checksum
                if let hash = key.imageHash { row.imageHash = hash }
                rewritten += 1
            }
            try? writeContext.save()
        }
        return rewritten
    }

    /// The hashed key for a row still carrying a legacy one, or nil when the row needs no change
    /// or cannot be converted.
    private static func rehashedKey(for row: ItemEntity,
                                    imagesDir: URL?) -> (checksum: String, imageHash: String?)? {
        guard let type = ClipboardContentType(rawValue: row.typeName) else { return nil }
        let prefix = "\(type.rawValue)\(ClipboardItem.legacyMark)"
        guard row.checksum.hasPrefix(prefix) else { return nil }
        let body = String(row.checksum.dropFirst(prefix.count))

        switch type {
        case .text, .url, .color, .file, .folder:
            // The legacy key is `"<type>:<content>"` for text and `"<type>:<paths>"` for files,
            // and both are exactly what the hashed key hashes — so the body is the input.
            return ("\(type.rawValue)\(ClipboardItem.digestMark)\(ClipboardItem.digest(Data(body.utf8)))",
                    nil)
        case .image:
            guard let imagesDir,
                  let jpeg = try? Data(contentsOf: imagesDir
                      .appendingPathComponent(row.id.uuidString + ".jpg"))
            else { return nil }
            let hash = ClipboardItem.digest(jpeg)
            return ("image\(ClipboardItem.digestMark)\(hash)", hash)
        }
    }

    // MARK: - Housekeeping

    /// Deletes payload rows no item points at.
    ///
    /// The cascade rule means this should find nothing. It is here because "should" is not
    /// "does": a save that fails part-way, or a store opened by a build whose rules differed, both
    /// leave rows that nothing can ever reach again, and their external blobs with them.
    @discardableResult
    func pruneOrphanedPayloads() -> Int {
        var removed = 0
        writeContext.performAndWait { [writeContext] in
            let request = NSFetchRequest<ItemDataEntity>(entityName: "ItemDataEntity")
            request.predicate = NSPredicate(format: "item == nil")
            guard let rows = try? writeContext.fetch(request), !rows.isEmpty else { return }
            removed = rows.count
            rows.forEach(writeContext.delete)
            try? writeContext.save()
        }
        return removed
    }

    /// The ids the store actually holds, for reconciling against a directory of image files.
    func storedIDs() -> Set<UUID> {
        let request = NSFetchRequest<NSDictionary>(entityName: "ItemEntity")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id"]
        var ids: Set<UUID> = []
        let context = container.viewContext
        context.performAndWait {
            guard let rows = try? context.fetch(request) else { return }
            for row in rows { if let id = row["id"] as? UUID { ids.insert(id) } }
        }
        return ids
    }

    // MARK: - Helpers

    fileprivate static func item(id: UUID, in context: NSManagedObjectContext) -> ItemEntity? {
        let request = NSFetchRequest<ItemEntity>(entityName: "ItemEntity")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return (try? context.fetch(request))?.first
    }

    fileprivate static func application(bundleIdentifier: String,
                                        in context: NSManagedObjectContext) -> ApplicationEntity {
        let request = NSFetchRequest<ApplicationEntity>(entityName: "ApplicationEntity")
        request.predicate = NSPredicate(format: "bundleIdentifier == %@", bundleIdentifier)
        request.fetchLimit = 1
        if let existing = (try? context.fetch(request))?.first { return existing }
        let created = ApplicationEntity(context: context)
        created.bundleIdentifier = bundleIdentifier
        created.createdAt = Date()
        return created
    }
}

// MARK: - Crossing the context boundary

/// A `ClipboardItem`'s hot fields, as plain values.
///
/// The write runs on the background context's own queue, and `ClipboardItem` holds only value
/// types — but the row it is written into does not exist yet at the call site, so what crosses is
/// this rather than a managed object. Keeping the copy explicit is also what stops a future field
/// from being added to the item and silently never persisted.
private struct ItemSnapshot {
    let id: UUID
    let typeName: String
    let timestamp: Date
    let isPinned: Bool
    let label: String?
    let checksum: String
    let previewText: String?
    let fullTextLength: Int64
    let ocrText: String?
    let revision: Int32
    let imageHash: String?
    let imageSize: Int64
    let rawFilePaths: Data?
    let richTypeName: String?
    let hasRichText: Bool
    let sourceAppBundleID: String?

    init(item: ClipboardItem) {
        id = item.id
        typeName = item.type.rawValue
        timestamp = item.timestamp
        isPinned = item.isPinned
        label = item.label
        checksum = item.checksum
        previewText = item.text.map { String($0.prefix(ItemEntity.previewCharLimit)) }
        fullTextLength = Int64(item.fullTextLength)
        ocrText = item.ocrText
        revision = Int32(item.contentRevision)
        imageHash = item.imageHash
        imageSize = Int64(item.imageSize ?? 0)
        rawFilePaths = item.fileURLs.flatMap { urls in
            try? PropertyListSerialization.data(fromPropertyList: urls.map(\.path),
                                                format: .binary, options: 0)
        }
        richTypeName = item.richType
        hasRichText = item.hasRichText
        sourceAppBundleID = item.sourceAppBundleID
    }

    func apply(to row: ItemEntity, in context: NSManagedObjectContext) {
        row.id = id
        row.typeName = typeName
        row.timestamp = timestamp
        row.isPinned = isPinned
        row.label = label
        row.checksum = checksum
        row.previewText = previewText
        row.fullTextLength = fullTextLength
        row.ocrText = ocrText
        row.revision = revision
        row.imageHash = imageHash
        row.imageSize = imageSize
        row.rawFilePaths = rawFilePaths
        row.richTypeName = richTypeName
        row.hasRichText = hasRichText
        if let sourceAppBundleID {
            row.sourceApplication = ClipboardDatabase.application(bundleIdentifier: sourceAppBundleID,
                                                                 in: context)
        } else {
            row.sourceApplication = nil
        }
    }
}

extension ClipboardItem {
    /// Rebuilds the in-memory item from a hot row. Nil when the row names a type this build does
    /// not know, which is what a history written by a newer version looks like.
    init?(row: ItemEntity) {
        guard let type = ClipboardContentType(rawValue: row.typeName) else { return nil }
        let paths = (row.rawFilePaths.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String]
        }) ?? nil

        self.init(
            id: row.id,
            type: type,
            text: row.previewText,
            imageData: nil,
            imageSize: row.imageSize > 0 ? Int(row.imageSize) : nil,
            imageHash: row.imageHash,
            fileURLs: paths.map { $0.map { URL(fileURLWithPath: $0) } },
            timestamp: row.timestamp,
            isPinned: row.isPinned,
            label: row.label,
            sourceAppBundleID: row.sourceApplication?.bundleIdentifier,
            ocrText: row.ocrText,
            richData: nil,
            richType: row.richTypeName,
            revision: Int(row.revision),
            hasRichText: row.hasRichText,
            fullTextLength: Int(row.fullTextLength),
            checksum: row.checksum
        )
    }
}
