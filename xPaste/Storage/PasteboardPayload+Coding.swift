import Foundation

/// A cheap content key for a blob: its length plus its first and last sixteen bytes.
///
/// Hashing a representation in full would mean walking every byte of an 8 MB screenshot to answer
/// a question — "have I already got this one?" — that is almost always answered by the length
/// alone. Collisions are allowed and dealt with by comparing the bytes; the key only has to be
/// cheap and rarely wrong, not unique. Same shape as `ClipboardItem.makeHash`, which does this for
/// image dedup at the item level.
struct BlobKey: Hashable {
    private let count: Int
    private let head: [UInt8]
    private let tail: [UInt8]

    init(_ data: Data) {
        count = data.count
        head = Array(data.prefix(16))
        tail = Array(data.suffix(16))
    }
}

/// Interns blobs so representations that carry identical bytes share one copy.
///
/// Worth being precise about what this is *not* for. A rich-text copy lists six types on
/// `pb.types` — `public.rtf` and the NeXT name, both plain-text flavours in both encodings — and
/// three of them are byte-identical duplicates of the other three. None of those reach capture:
/// `pasteboardItems` reports the canonical three (measured, 3 against 6) and AppKit re-derives the
/// aliases when the payload is written back. What is left is an app offering the same bytes under
/// both a public type and a private one of its own, which does happen and which the format can
/// express for free.
///
/// It has to be explicit either way, because binary plists do not unique `Data` — measured, 440
/// bytes for one blob against 802 for the same blob under two keys.
struct BlobTable {
    private(set) var blobs: [Data] = []
    private var index: [BlobKey: [Int]] = [:]

    /// The stored copy of `data`, or nil when these bytes are not held yet.
    ///
    /// Separate from `intern` so capture can ask before it decides. Asking by interning meant a
    /// blob entered the table before the size budget had accepted it — and then a second type
    /// carrying the same bytes was found "already present", so it was stored without ever being
    /// charged, behind a first type the budget had just refused.
    func stored(_ data: Data) -> Data? {
        for candidate in index[BlobKey(data), default: []] where blobs[candidate] == data {
            return blobs[candidate]
        }
        return nil
    }

    /// The stored copy of `data` — the existing one when the bytes are already held.
    @discardableResult
    mutating func intern(_ data: Data) -> Data {
        if let held = stored(data) { return held }
        blobs.append(data)
        index[BlobKey(data), default: []].append(blobs.count - 1)
        return data
    }

    /// The index of `data`, adding it when absent.
    mutating func offset(of data: Data) -> Int {
        let key = BlobKey(data)
        for candidate in index[key, default: []] where blobs[candidate] == data { return candidate }
        blobs.append(data)
        index[key, default: []].append(blobs.count - 1)
        return blobs.count - 1
    }
}

extension PasteboardPayload {

    /// Version stamp on the encoded form.
    ///
    /// Read on the way in and refused when unknown, so a history written by a newer build is
    /// skipped rather than misread. There is nothing to migrate at version 1; the field is here so
    /// that there can be.
    static let formatVersion = 1

    private enum Key {
        static let version = "v"
        static let items = "items"
        static let types = "types"
        static let offsets = "blobs"
        static let blobs = "blobs"
    }

    /// The bytes to store.
    ///
    /// A blob table with indices rather than Paste's `{types, dataByType}` map, for the one reason
    /// that map cannot express: a representation whose bytes another representation already holds
    /// is written once and pointed at twice.
    func encoded() throws -> Data {
        var table = BlobTable()
        var encodedItems: [[String: Any]] = []

        for item in items {
            var types: [String] = []
            var offsets: [Int] = []
            for type in item.types {
                guard let data = item.dataByType[type] else { continue }
                types.append(type)
                offsets.append(table.offset(of: data))
            }
            encodedItems.append([Key.types: types, Key.offsets: offsets])
        }

        let root: [String: Any] = [
            Key.version: Self.formatVersion,
            Key.items: encodedItems,
            Key.blobs: table.blobs,
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    /// Rebuilds a payload from `encoded()`'s bytes, or nil when they are not a payload this build
    /// understands. Nil rather than a throw: a single unreadable item must not be able to stop the
    /// history from loading.
    init?(decoding data: Data) {
        guard let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let version = root[Key.version] as? Int, version == Self.formatVersion,
              let rawItems = root[Key.items] as? [[String: Any]],
              let blobs = root[Key.blobs] as? [Data]
        else { return nil }

        var decoded: [Item] = []
        for raw in rawItems {
            guard let types = raw[Key.types] as? [String],
                  let offsets = raw[Key.offsets] as? [Int],
                  types.count == offsets.count
            else { return nil }

            var dataByType: [String: Data] = [:]
            var kept: [String] = []
            for (type, offset) in zip(types, offsets) {
                guard blobs.indices.contains(offset) else { return nil }
                dataByType[type] = blobs[offset]
                kept.append(type)
            }
            decoded.append(Item(types: kept, dataByType: dataByType))
        }
        self.items = decoded
    }
}
