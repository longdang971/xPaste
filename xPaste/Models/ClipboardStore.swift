import Foundation
import AppKit
import Combine

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore(maxItems: 500)

    // Deliberately not `@Published`: see `publishingSuppressed`.
    private(set) var items: [ClipboardItem] = [] {
        willSet { notifyWillChange() }
        didSet { _cachedFilteredItems = nil }
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

    private func notifyWillChange() {
        if publishingSuppressed { pendingChange = true } else { objectWillChange.send() }
    }
    @Published var searchQuery = "" {
        didSet { _cachedFilteredItems = nil }
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
    private let itemsDir: URL?
    private let imagesDir: URL?
    private let saveQueue = DispatchQueue(label: "com.user.xPaste.save", qos: .background)

    private var _cachedFilteredItems: [ClipboardItem]?

    private let imageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 50
        return c
    }()

    init(maxItems: Int, storageDir: URL? = ClipboardStore.defaultStorageDir()) {
        self.defaultMaxItems = maxItems
        self.itemsDir  = storageDir?.appendingPathComponent("items",  isDirectory: true)
        self.imagesDir = storageDir?.appendingPathComponent("images", isDirectory: true)

        if let itemsDir, let imagesDir {
            try? FileManager.default.createDirectory(at: itemsDir,  withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            if let storageDir { migrateFromLegacyIfNeeded(in: storageDir) }
            load()
            trim()          // enforce the count cap at launch too, not only on the next add()
            pruneExpired()
        }
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
        imageCache.setObject(image, forKey: key)
        return image
    }

    var filteredItems: [ClipboardItem] {
        if let cached = _cachedFilteredItems { return cached }
        let result = computeFilteredItems()
        _cachedFilteredItems = result
        return result
    }

    private func computeFilteredItems() -> [ClipboardItem] {
        let sorted = items.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.timestamp > $1.timestamp
        }
        guard !searchQuery.isEmpty else { return sorted }
        return sorted.filter { item in
            switch item.type {
            case .text, .url:
                return item.text?.localizedCaseInsensitiveContains(searchQuery) ?? false
            case .file, .folder:
                return item.displayText.localizedCaseInsensitiveContains(searchQuery)
            case .image:
                return item.displayText.localizedCaseInsensitiveContains(searchQuery)
            }
        }
    }

    func add(_ item: ClipboardItem) {
        let removedIDs: [UUID] = items.compactMap { existing in
            guard !existing.isPinned, existing.type == item.type else { return nil }
            switch item.type {
            case .text, .url:
                return existing.text == item.text ? existing.id : nil
            case .image:
                if let eh = existing.imageHash, let nh = item.imageHash { return eh == nh ? existing.id : nil }
                guard let ed = existing.imageData, let nd = item.imageData else { return nil }
                return ed == nd ? existing.id : nil
            case .file, .folder:
                return existing.fileURLs == item.fileURLs ? existing.id : nil
            }
        }
        for id in removedIDs {
            deleteFiles(for: id)
            imageCache.removeObject(forKey: id.uuidString as NSString)
        }
        items.removeAll { removedIDs.contains($0.id) }

        if let data = item.imageData, let imagesDir {
            let imgURL = imagesDir.appendingPathComponent(item.id.uuidString + ".jpg")
            saveQueue.async { try? data.write(to: imgURL, options: .atomic) }
            if let image = NSImage(data: data) {
                imageCache.setObject(image, forKey: item.id.uuidString as NSString)
            }
        }

        items.insert(item, at: 0)
        trim()
        pruneExpired()
        writeMetadata(item)
    }

    func delete(_ item: ClipboardItem) {
        imageCache.removeObject(forKey: item.id.uuidString as NSString)
        items.removeAll { $0.id == item.id }
        deleteFiles(for: item.id)
    }

    func togglePin(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
        writeMetadata(items[idx])
    }

    func moveToTop(_ item: ClipboardItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        var moved = items.remove(at: idx)
        moved.timestamp = Date()
        items.insert(moved, at: 0)
        writeMetadata(moved)
    }

    func deleteItems(ids: Set<UUID>) {
        ids.forEach {
            deleteFiles(for: $0)
            imageCache.removeObject(forKey: $0.uuidString as NSString)
        }
        items.removeAll { ids.contains($0.id) }
    }

    func clearUnpinned() {
        items.filter { !$0.isPinned }.forEach {
            deleteFiles(for: $0.id)
            imageCache.removeObject(forKey: $0.id.uuidString as NSString)
        }
        items.removeAll { !$0.isPinned }
    }

    func clearAll() {
        items.forEach { imageCache.removeObject(forKey: $0.id.uuidString as NSString) }
        items.removeAll()
        let dirs = [itemsDir, imagesDir].compactMap { $0 }
        // Tear the directories down ON the save queue so it runs AFTER any in-flight
        // metadata/image writes. Doing it on the main thread races those writes, which can
        // drop a file into the freshly recreated dir and resurrect a "ghost" item on relaunch.
        saveQueue.async {
            let fm = FileManager.default
            for dir in dirs {
                try? fm.removeItem(at: dir)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
    }

    private func writeMetadata(_ item: ClipboardItem) {
        guard let itemsDir else { return }
        let url = itemsDir.appendingPathComponent(item.id.uuidString + ".json")
        saveQueue.async {
            if let data = try? JSONEncoder().encode(item) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func deleteFiles(for id: UUID) {
        guard let itemsDir, let imagesDir else { return }
        let metaURL = itemsDir.appendingPathComponent(id.uuidString + ".json")
        let imgURL  = imagesDir.appendingPathComponent(id.uuidString + ".jpg")
        saveQueue.async {
            try? FileManager.default.removeItem(at: metaURL)
            try? FileManager.default.removeItem(at: imgURL)
        }
    }

    private func load() {
        guard let itemsDir else { return }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: itemsDir, includingPropertiesForKeys: nil
        ) else { return }

        let jsonURLs = urls.filter { $0.pathExtension == "json" }
        guard !jsonURLs.isEmpty else { return }

        var results = [ClipboardItem?](repeating: nil, count: jsonURLs.count)
        DispatchQueue.concurrentPerform(iterations: jsonURLs.count) { i in
            let decoder = JSONDecoder()
            guard let data = try? Data(contentsOf: jsonURLs[i]),
                  let item = try? decoder.decode(ClipboardItem.self, from: data)
            else { return }
            results[i] = item
        }

        items = results.compactMap { $0 }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.timestamp > $1.timestamp
        }
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
        let expiredIDs = Set(items.filter { !$0.isPinned && $0.timestamp < cutoff }.map(\.id))
        guard !expiredIDs.isEmpty else { return }
        expiredIDs.forEach {
            deleteFiles(for: $0)
            imageCache.removeObject(forKey: $0.uuidString as NSString)
        }
        items.removeAll { expiredIDs.contains($0.id) }
    }

    /// Enforce the count cap now — call after the user lowers the history slider so
    /// the oldest unpinned items over the new limit are pruned immediately.
    func enforceHistoryLimit() { trim() }

    private func trim() {
        let unpinned = items.filter { !$0.isPinned }.sorted { $0.timestamp < $1.timestamp }
        guard unpinned.count > maxItems else { return }
        let toRemove = unpinned.prefix(unpinned.count - maxItems)
        toRemove.forEach {
            deleteFiles(for: $0.id)
            imageCache.removeObject(forKey: $0.id.uuidString as NSString)
        }
        let removeIDs = Set(toRemove.map(\.id))
        items.removeAll { removeIDs.contains($0.id) }
    }

    private func migrateFromLegacyIfNeeded(in dir: URL) {
        let legacyURL = dir.appendingPathComponent("history.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL)
        else { return }

        struct LegacyItem: Decodable {
            let id: UUID
            let type: ClipboardContentType
            let text: String?
            let imageData: Data?
            let fileURLs: [URL]?
            let timestamp: Date
            let isPinned: Bool
            let label: String?
            let sourceAppBundleID: String?
        }

        guard let legacyItems = try? JSONDecoder().decode([LegacyItem].self, from: data) else { return }

        let encoder = JSONEncoder()
        for legacy in legacyItems {
            let item = ClipboardItem(
                id: legacy.id, type: legacy.type, text: legacy.text,
                imageData: legacy.imageData, fileURLs: legacy.fileURLs,
                timestamp: legacy.timestamp, isPinned: legacy.isPinned,
                label: legacy.label, sourceAppBundleID: legacy.sourceAppBundleID
            )
            if let imgData = legacy.imageData, let imagesDir {
                try? imgData.write(to: imagesDir.appendingPathComponent(legacy.id.uuidString + ".jpg"))
            }
            if let metaData = try? encoder.encode(item), let itemsDir {
                try? metaData.write(to: itemsDir.appendingPathComponent(legacy.id.uuidString + ".json"))
            }
        }

        try? FileManager.default.removeItem(at: legacyURL)
    }

    static func defaultStorageDir() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent("xPaste", isDirectory: true)
    }
}
