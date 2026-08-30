import Foundation
import AppKit
import Combine

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore(maxItems: 500)

    // Deliberately not `@Published`: see `publishingSuppressed`.
    private(set) var items: [ClipboardItem] = [] {
        willSet { notifyWillChange() }
        didSet { invalidateCaches() }
    }

    /// Silences SwiftUI updates while nothing is on screen.
    ///
    /// Every copy made anywhere in the system lands here. With the panel hidden, the resulting
    /// update cost 39ms of SwiftUI layout against 1.1ms of actual store work — all of it to
    /// re-lay-out a window the user cannot see. Changes are coalesced while suppressed and
    /// published once, when this is switched back off.
    var publishingSuppressed = false {
        didSet {
            guard !publishingSuppressed, pendingChange else { return }
            pendingChange = false
            objectWillChange.send()
        }
    }
    private var pendingChange = false

    /// Whether a change has been coalesced away and is still waiting to be published.
    var hasPendingChange: Bool { pendingChange }

    /// Called on the main thread whenever a change is coalesced while suppressed, so the panel
    /// can pay the resulting SwiftUI re-layout at an idle moment instead of on the open path.
    var onPendingChange: (() -> Void)?

    private func notifyWillChange() {
        if publishingSuppressed {
            let wasPending = pendingChange
            pendingChange = true
            if !wasPending { onPendingChange?() }
        } else {
            objectWillChange.send()
        }
    }
    @Published var searchQuery = "" {
        didSet { invalidateCaches() }
    }

    /// The part of the search box that cards paint yellow.
    ///
    /// Only the free text: `img:` and `app:chrome` narrow the list by an item's type or its source
    /// app, neither of which is a string written anywhere on the card, so there is nothing on a
    /// card for them to mark.
    var highlightTerm: String {
        searchQuery.isEmpty ? "" : SearchQuery.parse(searchQuery).text
    }

    /// Type / app / date switches from the filter popover, applied on top of `searchQuery`.
    @Published var filters = SearchFilters() {
        didSet { invalidateCaches() }
    }

    private func invalidateCaches() {
        _cachedFilteredItems = nil
        _cachedPinnedItems = nil
    }

    /// Card scale for the screen the panel currently sits on. AppDelegate sets this from the
    /// SAME screen it sizes the panel frame with, so cards and the bar never disagree across
    /// displays of different logical heights. Read by ContentView via the `panelScale` environment.
    @Published var panelScale: CGFloat = 1

    // NOT @Published: this is only read lazily when building an item's context menu
    // ("Paste to <app>"). Publishing it invalidated the entire ContentView on every
    // panel open, forcing a ~110ms synchronous re-layout before the panel could animate in.
    var targetAppName: String?

    static let minHistoryCount = 500
    static let maxHistoryCount = 3000

    /// Fallback cap used when the user hasn't picked one yet (from init).
    private let defaultMaxItems: Int
    /// Effective cap on unpinned items, driven by the "maxHistoryCount" slider in Settings
    /// and clamped to the supported range. Pinned items are never counted or removed.
    private var maxItems: Int {
        let stored = UserDefaults.standard.object(forKey: "maxHistoryCount") as? Int ?? defaultMaxItems
        return min(Self.maxHistoryCount, max(Self.minHistoryCount, stored))
    }
    /// Where the history lives. Nil when the store has nowhere to write, which is what the tests
    /// that do not care about persistence use.
    private let database: ClipboardDatabase?
    private let imagesDir: URL?

    /// Checksum → id, kept in step with `items`, so "have I already got this?" is a lookup.
    ///
    /// The store's own index answers the same question, but not from here: dedup runs on the main
    /// thread inside `add`, and going to the database for it would put a fetch on the path every
    /// copy in the system takes. This mirrors it in memory for that one question.
    private var idsByChecksum: [String: Set<UUID>] = [:]
    /// Utility rather than background: this queue now carries the *only* copy of a freshly
    /// captured image, and background work can be starved for seconds under load — long enough for
    /// a paste or a save to look for a file that has not been written yet.
    private let saveQueue = DispatchQueue(label: "com.user.xPaste.save", qos: .utility)

    private var _cachedFilteredItems: [ClipboardItem]?
    private var _cachedPinnedItems: [ClipboardItem]?

    /// Decoded pictures, bounded by what they cost rather than by how many there are.
    ///
    /// A count limit is no limit at all here — see `NSImage.approximateDecodedBytes`. The count
    /// stays as a second bound so a history of small images cannot fill it with entries either.
    private let imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 50
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    init(maxItems: Int, storageDir: URL? = ClipboardStore.defaultStorageDir()) {
        self.defaultMaxItems = maxItems
        self.imagesDir = storageDir?.appendingPathComponent("images", isDirectory: true)
        self.database = ClipboardDatabase(storageDir: storageDir)

        guard let database else { return }
        if let imagesDir {
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }
        if let storageDir { LegacyJSONImport.run(from: storageDir, into: database) }
        load()
        trim()          // enforce the count cap at launch too, not only on the next add()
        pruneExpired()
        // Rows whose item is gone, and image files whose item is gone. Both are unreachable bytes
        // and nothing else; both are cheap to look for and neither is guaranteed absent — see
        // `pruneOrphanedPayloads`.
        database.pruneOrphanedPayloads()
        pruneOrphanedImages()
    }

    /// Waits for every queued write to reach disk.
    ///
    /// The queue is serial, so an empty block behind the backlog returns only once the backlog has
    /// gone. Quitting without this loses whatever had not been written yet — measured at four of
    /// six item files and the whole of an image when the app was closed straight after copying.
    func flushPendingWrites() {
        saveQueue.sync {}
        database?.flush()
    }

    /// An image's bytes, from the one place that has them.
    ///
    /// `add` drops the in-memory buffer as soon as the write is queued, so the file is the only
    /// copy — and a reader arriving before the queue has drained would find nothing and conclude
    /// the picture was gone. Draining first is cheap (the queue is normally empty) and it is the
    /// difference between pasting a picture and pasting nothing.
    func imageBytes(for id: UUID) -> Data? {
        flushPendingWrites()
        guard let url = imageURL(for: id) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Every representation stored for an item, faulted in from the database.
    ///
    /// This is the cold half of the split, and the whole reason a card never touches it: drawing
    /// the history means materialising every row in it, and a row that carried its payload would
    /// mean loading every representation of every item to draw a list of titles.
    func payload(for id: UUID) -> PasteboardPayload? {
        database?.payload(for: id)
    }

    /// The formatted bytes for an item — from the item when it still carries them, from the store
    /// otherwise. Mirrors `imageBytes(for:)`, and for the same reason.
    func richBytes(for item: ClipboardItem) -> Data? {
        if let inHand = item.richData, !inHand.isEmpty { return inHand }
        guard item.hasRichText, let type = item.richType else { return nil }
        return payload(for: item.id)?.data(forType: type)
    }

    /// The item's full text, which `item.text` may be a prefix of.
    func fullText(for item: ClipboardItem) -> String? {
        guard item.isTextTruncated else { return item.text }
        return payload(for: item.id)?.string ?? item.text
    }

    /// The item with its cold half filled in.
    ///
    /// Anything that pastes, saves, drags or edits an item must go through this: those are the
    /// paths where a prefix of the text is the wrong answer, and the only ones that are worth a
    /// disk read. Everything that merely draws or searches reads the hot fields directly.
    func hydrated(_ item: ClipboardItem) -> ClipboardItem {
        guard item.isTextTruncated || (item.hasRichText && item.richData == nil) else { return item }
        var full = item
        if let payload = payload(for: item.id) {
            full.payload = payload
            if item.isTextTruncated, let text = payload.string { full.text = text }
            if item.richData == nil, let type = item.richType {
                full.richData = payload.data(forType: type)
            }
        }
        return full
    }

    /// The picture as the source app put it on the clipboard.
    ///
    /// `imageBytes` returns the other one: a re-encode capped at a megabyte, which exists so a card
    /// can be drawn without decoding a 63 MB screenshot. That copy is the card's and nobody else's.
    /// Everything that hands the picture on — a paste, a drag into Finder, a Save as File, a share,
    /// and the OCR that has to read small text in it — wants what was actually copied.
    ///
    /// Falls back to the re-encode for items imported from the JSON history: that format never kept
    /// an original, so for those two there is only ever one picture.
    func originalImageBytes(for item: ClipboardItem) -> Data? {
        if let payload = item.payload ?? payload(for: item.id),
           let picture = payload.imageRepresentation {
            return picture.data
        }
        return item.imageData ?? imageBytes(for: item.id)
    }

    /// The original, decoded, for a view that shows one picture at a time.
    ///
    /// Deliberately not through `imageCache`. That cache is bounded at 64 MB because it holds the
    /// thumbnails of everything scrolled past; one original can be twice that on its own, so
    /// putting one in would evict the whole cache to hold a single image the moment a preview is
    /// opened. This decodes, hands it over, and lets it go with the window.
    func loadOriginalImage(for item: ClipboardItem) async -> NSImage? {
        guard item.type == .image else { return nil }
        let bytes = await Task.detached(priority: .userInitiated) { [weak self] in
            self?.originalImageBytes(for: item)
        }.value
        guard let bytes else { return nil }
        return NSImage(data: bytes)
    }

    func imageURL(for id: UUID) -> URL? {
        imagesDir?.appendingPathComponent(id.uuidString + ".jpg")
    }

    func loadImage(for id: UUID) async -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let imagesDir else { return nil }
        let url = imagesDir.appendingPathComponent(id.uuidString + ".jpg")
        guard let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key, cost: image.approximateDecodedBytes)
        return image
    }

    var filteredItems: [ClipboardItem] {
        if let cached = _cachedFilteredItems { return cached }
        let result = computeFilteredItems()
        _cachedFilteredItems = result
        return result
    }

    /// The Pinned tab's list, narrowed the same way and cached the same way as `filteredItems`.
    /// `ContentView` reads it several times per body pass, so recomputing it each time meant
    /// filtering the whole history four times over to draw one panel.
    var pinnedFilteredItems: [ClipboardItem] {
        if let cached = _cachedPinnedItems { return cached }
        let result = narrow(items.filter(\.isPinned))
        _cachedPinnedItems = result
        return result
    }

    private func computeFilteredItems() -> [ClipboardItem] {
        let sorted = items.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.timestamp > $1.timestamp
        }
        return narrow(sorted)
    }

    /// Applies the popover's filters and the search box to any list of items. Shared so the
    /// Pinned tab, which builds its own list, narrows it exactly the same way.
    func narrow(_ items: [ClipboardItem]) -> [ClipboardItem] {
        // `img:`, `app:chrome`, free text — see SearchQuery. A query made only of filter tokens
        // (`img:` alone) still filters; one that parses to nothing at all is ignored.
        let query = searchQuery.isEmpty ? nil : SearchQuery.parse(searchQuery)
        let activeQuery = (query?.isEmpty ?? true) ? nil : query
        guard !filters.isEmpty || activeQuery != nil else { return items }
        let resolver = AppNameResolver.shared
        // One "now" for the whole pass: sampling Date() per item would let a date-window edge
        // move underneath the filter mid-list.
        let now = Date()
        let calendar = Calendar.current
        return items.filter { item in
            guard filters.matches(item, now: now, calendar: calendar) else { return false }
            guard let activeQuery else { return true }
            return activeQuery.matches(item, appName: { resolver.name(for: $0) })
        }
    }

    func add(_ item: ClipboardItem) {
        var item = item
        // By checksum through the index rather than by walking the history: this runs on the main
        // thread for every copy made anywhere in the system, and the walk it replaces compared the
        // full text of every item of the same type on the way past.
        let candidates = idsByChecksum[item.checksum] ?? []
        let removedIDs: [UUID] = candidates.isEmpty ? [] : items.compactMap { existing in
            guard candidates.contains(existing.id), !existing.isPinned else { return nil }
            return existing.id
        }
        if !removedIDs.isEmpty {
            unindex(items.filter { removedIDs.contains($0.id) })
            removedIDs.forEach { forget($0) }
            items.removeAll { removedIDs.contains($0.id) }
            database?.delete(ids: removedIDs)
        }

        if let data = item.imageData, let imagesDir {
            let imgURL = imagesDir.appendingPathComponent(item.id.uuidString + ".jpg")
            saveQueue.async { try? data.write(to: imgURL, options: .atomic) }
            // Deliberately not decoded here. Caching it on capture meant every picture copied was
            // decoded whether or not anyone ever looked at it — twenty-five copies in a row cost
            // hundreds of megabytes for cards that were never drawn. `loadImage` decodes the ones
            // a card actually shows, and the file is written just below.
            // Let the buffer go now that it is on its way to disk.
            //
            // `imageData` is not in `CodingKeys`, so an item restored at launch never carries one —
            // the whole design reads pixels back from disk through a count-bounded cache. An item
            // added during the session was the exception, and it kept its full buffer in the array
            // for as long as the app ran: forty screenshots measured at 36 MB, and the cap is 3000
            // items. Every reader already falls back to the file, so there is nothing to keep.
            item.imageData = nil
        }

        let payload = item.payload
        // Dropped for the same reason `imageData` is, and it matters more: the payload is every
        // representation the source offered, and keeping it on the item would put all of them in
        // the array for as long as the app runs — the exact cost this schema exists to avoid.
        item.payload = nil

        items.insert(item, at: 0)
        index(item)
        trim()
        pruneExpired()
        database?.upsert(item, payload: payload)
    }

    /// Records an item in the checksum index.
    private func index(_ item: ClipboardItem) {
        idsByChecksum[item.checksum, default: []].insert(item.id)
    }

    /// Removes ids from the checksum index. Takes the items rather than the ids because a checksum
    /// is derived from content, and the content is what has just been removed from `items`.
    private func unindex(_ removed: [ClipboardItem]) {
        for item in removed {
            idsByChecksum[item.checksum]?.remove(item.id)
            if idsByChecksum[item.checksum]?.isEmpty == true { idsByChecksum[item.checksum] = nil }
        }
    }

    func delete(_ item: ClipboardItem) {
        deleteItems(ids: [item.id])
    }

    func togglePin(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
        writeMetadata(items[idx])
    }

    /// Names an item (or clears the name when `label` is nil/blank).
    func setLabel(_ label: String?, for id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard items[idx].label != newValue else { return }
        items[idx].label = newValue
        writeMetadata(items[idx])
    }

    /// Replaces an item's content with what came out of the editor.
    ///
    /// Only Text, Link and Color items, and never with nothing: deleting is a separate gesture with
    /// its own confirmation, so a save that emptied an item would be a way to lose one by accident.
    ///
    /// The type is decided again from the new text — an edit that turns prose into a URL turns a
    /// Text card into a Link card, and one that turns a colour into prose turns a Color card into a
    /// Text card — using the rule capture uses, so the two cannot disagree.
    ///
    /// Position and timestamp are left alone. The timestamp records when the content was copied,
    /// and editing is not copying.
    func updateContent(id: UUID, text: String, richData: Data?, richType: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard ItemEdit.canEdit(items[idx].type) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Built up on a copy and written back once. `items` carries willSet/didSet, so every
        // assignment through the subscript is a separate `objectWillChange` — five of them for one
        // edit, each one a full SwiftUI pass over the panel.
        let previous = items[idx]
        var edited = previous
        edited.text = text
        edited.richData = richData
        edited.richType = richData == nil ? nil : richType
        edited.hasRichText = richData != nil
        edited.fullTextLength = text.count
        edited.type = ClipboardItem.contentType(for: text)
        edited.revision = edited.contentRevision + 1
        // Recomputed, not carried over: `edited` started as a copy of the item before the edit, so
        // its key still describes the old text. Leaving it would file the item under what it used
        // to say — and the next copy of that old text would dedup this one away.
        edited.checksum = ClipboardItem.makeChecksum(type: edited.type, id: edited.id, text: text,
                                                     imageHash: edited.imageHash,
                                                     fileURLs: edited.fileURLs)
        items[idx] = edited

        // The checksum is derived from the content, so an edit moves the item to a different
        // bucket. Missing this leaves it findable under what it used to say, which is how an edited
        // item gets silently deduplicated away by the next copy of its own old text.
        unindex([previous])
        index(edited)

        forgetCachedContent(for: id)
        // Rewritten in full rather than as metadata: the payload's plain and formatted
        // representations are what a paste replays, and leaving them at the pre-edit text would
        // mean the card shows one thing and pasting produces another.
        let base = payload(for: id) ?? PasteboardPayload.plainText(text)
        let updated = base.replacingText(text, rich: richData.map { ($0, richType ?? ItemEdit.richType) })
        database?.upsert(edited, payload: updated)
    }

    /// The caches that key on an item's id and stop being true the moment its content changes.
    ///
    /// Called from here rather than left to each caller because there is exactly one way an item's
    /// content changes, and a cache that nobody remembered to purge does not fail — it quietly
    /// serves the old text, which is far worse. The card's `@State` is the one cache out of reach
    /// from here; `ClipboardItem.revision` is what deals with that.
    private func forgetCachedContent(for id: UUID) {
        RichTextRenderer.forget(id)
        ClipboardItemCard.forgetContent(for: id)
    }

    /// Records what OCR read out of an image. Writing an empty string is meaningful: it marks
    /// the item as scanned so the backfill never looks at it again.
    func setOCRText(_ text: String, for id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].ocrText != text else { return }
        items[idx].ocrText = text
        writeMetadata(items[idx])
    }

    /// Image items that have never been through OCR, newest first — the backfill works through
    /// recent screenshots before old ones, since those are what people look for.
    func itemsAwaitingOCR() -> [ClipboardItem] {
        items.filter { $0.type == .image && $0.ocrText == nil }
    }

    func moveToTop(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        // Reordered on a copy and written back once. A remove and an insert are two mutations of a
        // property with observers, so this cost two full SwiftUI passes over the panel for one move.
        var reordered = items
        var moved = reordered.remove(at: idx)
        moved.timestamp = Date()
        reordered.insert(moved, at: 0)
        items = reordered
        writeMetadata(moved)
    }

    func deleteItems(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        unindex(items.filter { ids.contains($0.id) })
        ids.forEach { forget($0) }
        items.removeAll { ids.contains($0.id) }
        database?.delete(ids: Array(ids))
    }

    func clearUnpinned() {
        deleteItems(ids: Set(items.filter { !$0.isPinned }.map(\.id)))
    }

    func clearAll() {
        items.forEach { forget($0.id) }
        items.removeAll()
        idsByChecksum.removeAll()
        database?.deleteAll()
        guard let imagesDir else { return }
        // Torn down ON the save queue so it runs AFTER any in-flight image write. On the main
        // thread it races them, which can drop a file into the freshly recreated directory and
        // leave a picture behind for an item that no longer exists.
        saveQueue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: imagesDir)
            try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }
    }

    /// Persists an item's hot fields, leaving its payload alone.
    ///
    /// Every caller here is a metadata change — a pin, a rename, an OCR result, a reorder — and
    /// none of them touch the representations. Passing nil is what says so; see
    /// `ClipboardDatabase.upsert`.
    private func writeMetadata(_ item: ClipboardItem) {
        database?.upsert(item, payload: nil)
    }

    /// Drops an item's in-memory caches and its picture on disk. The database row is deleted by the
    /// caller, in one batch — see `deleteItems`.
    private func forget(_ id: UUID) {
        imageCache.removeObject(forKey: id.uuidString as NSString)
        guard let imagesDir else { return }
        let imgURL = imagesDir.appendingPathComponent(id.uuidString + ".jpg")
        saveQueue.async { try? FileManager.default.removeItem(at: imgURL) }
    }

    /// Deletes pictures no item claims.
    ///
    /// The database owns the payloads and takes them with the row; images live beside it as files
    /// and do not. A write that lands after its item was deleted, or a crash between the two, is
    /// enough to leave one — and nothing would ever look at it again.
    private func pruneOrphanedImages() {
        guard let imagesDir, let database else { return }
        let live = database.storedIDs()
        saveQueue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil)
            else { return }
            for file in files where file.pathExtension == "jpg" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      !live.contains(id)
                else { continue }
                try? fm.removeItem(at: file)
            }
        }
    }

    private func load() {
        guard let database else { return }
        // Sorted by the store, on an index that covers exactly this order — see
        // `ClipboardSchema`'s `byPinnedAndTimestamp`. What used to happen here was a directory
        // listing, a concurrent decode of every JSON file in it, and a sort of the result.
        items = database.loadItems().map { item -> ClipboardItem in
            // Colour became a type of its own after some of these items were stored, so a colour
            // copied before that is on disk as `.text`. Reclassifying on load is what stops there
            // being two classes of colour item — old ones the editor treats as prose, new ones it
            // does not. Cheap: `ColorParser`'s length gate rejects anything over 64 bytes before it
            // looks at the string.
            guard item.type == .text, let text = item.text,
                  ClipboardItem.contentType(for: text) == .color
            else { return item }
            var reclassified = item
            reclassified.type = .color
            return reclassified
        }
        items.forEach(index)
    }

    static let keepHistoryDaysByIndex = [1, 7, 30, 365, 0]

    private var keepHistoryDays: Int {
        let idx = UserDefaults.standard.object(forKey: "keepHistoryIndex") as? Int ?? 4
        guard Self.keepHistoryDaysByIndex.indices.contains(idx) else { return 0 }
        return Self.keepHistoryDaysByIndex[idx]
    }

    func pruneExpired() {
        let days = keepHistoryDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        deleteItems(ids: Set(items.filter { !$0.isPinned && $0.timestamp < cutoff }.map(\.id)))
    }

    /// Enforce the count cap now — call after the user lowers the history slider so
    /// the oldest unpinned items over the new limit are pruned immediately.
    func enforceHistoryLimit() { trim() }

    private func trim() {
        let unpinned = items.filter { !$0.isPinned }.sorted { $0.timestamp < $1.timestamp }
        guard unpinned.count > maxItems else { return }
        deleteItems(ids: Set(unpinned.prefix(unpinned.count - maxItems).map(\.id)))
    }

    static func defaultStorageDir() -> URL {
        // `XPASTE_STORAGE_DIR` points a run at a history of its own. The perf harness injects items
        // and deletes them again, and the installed copy is normally running against the real
        // directory at the same time — two processes writing one history is how a test run ends up
        // deleting somebody's clipboard. Unset in every ordinary launch.
        if let override = ProcessInfo.processInfo.environment["XPASTE_STORAGE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        // Under XCTest, somewhere disposable — never the real history.
        //
        // Not belt-and-braces. `ClipboardStore.shared` is reachable from `ClipboardItem.write`,
        // `RichTextRenderer.parse` and `hydrated`, so merely touching one of those in a test builds
        // the shared store against whatever this returns; and opening the real directory now runs
        // a migration that takes the old files away when it is done. Setting the variable in the
        // scheme would work until someone ran the tests another way, which is how this was found.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("xPaste-tests", isDirectory: true)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent("xPaste", isDirectory: true)
    }
}
