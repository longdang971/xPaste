import XCTest
@testable import xPaste

final class ClipboardStoreTests: XCTestCase {

    var store: ClipboardStore!

    override func setUp() {
        super.setUp()
        store = ClipboardStore(maxItems: 5, storageDir: nil)
    }

    func test_add_inserts_newest_first() {
        store.add(ClipboardItem(type: .text, text: "first"))
        store.add(ClipboardItem(type: .text, text: "second"))

        XCTAssertEqual(store.items.first?.text, "second")
    }

    func test_add_deduplicates_same_text() {
        store.add(ClipboardItem(type: .text, text: "duplicate"))
        store.add(ClipboardItem(type: .text, text: "duplicate"))

        XCTAssertEqual(store.items.count, 1)
    }

    func test_add_dedup_does_not_remove_pinned() {
        var pinned = ClipboardItem(type: .text, text: "important")
        pinned.isPinned = true
        store.add(pinned)
        store.add(ClipboardItem(type: .text, text: "important"))

        XCTAssertTrue(store.items.contains { $0.isPinned })
    }

    func test_trim_never_removes_pinned() {
        var pinned = ClipboardItem(type: .text, text: "keep me")
        pinned.isPinned = true
        store.add(pinned)
        for i in 0..<7 {
            store.add(ClipboardItem(type: .text, text: "item \(i)"))
        }

        XCTAssertTrue(store.items.contains { $0.isPinned && $0.text == "keep me" })
    }

    func test_delete_removes_item_by_id() {
        let item = ClipboardItem(type: .text, text: "gone")
        store.add(item)
        store.delete(item)

        XCTAssertFalse(store.items.contains { $0.id == item.id })
    }

    func test_togglePin_pins_unpinned_item() {
        let item = ClipboardItem(type: .text, text: "pin me")
        store.add(item)
        store.togglePin(store.items.first!)

        XCTAssertTrue(store.items.first!.isPinned)
    }

    func test_togglePin_unpins_pinned_item() {
        var item = ClipboardItem(type: .text, text: "unpin me")
        item.isPinned = true
        store.add(item)
        store.togglePin(store.items.first!)

        XCTAssertFalse(store.items.first!.isPinned)
    }

    func test_filteredItems_filters_by_searchQuery() {
        store.add(ClipboardItem(type: .text, text: "hello world"))
        store.add(ClipboardItem(type: .text, text: "foo bar"))
        store.searchQuery = "hello"

        XCTAssertEqual(store.filteredItems.count, 1)
        XCTAssertEqual(store.filteredItems.first?.text, "hello world")
    }

    func test_filteredItems_empty_query_returns_all() {
        store.add(ClipboardItem(type: .text, text: "a"))
        store.add(ClipboardItem(type: .text, text: "b"))
        store.searchQuery = ""

        XCTAssertEqual(store.filteredItems.count, 2)
    }

    func test_filteredItems_pinned_appear_first() {
        store.add(ClipboardItem(type: .text, text: "unpinned"))
        var pinned = ClipboardItem(type: .text, text: "pinned")
        pinned.isPinned = true
        store.add(pinned)

        XCTAssertTrue(store.filteredItems.first!.isPinned)
    }

    func test_clearUnpinned_keeps_pinned_removes_unpinned() {
        var pinned = ClipboardItem(type: .text, text: "keep")
        pinned.isPinned = true
        store.add(pinned)
        store.add(ClipboardItem(type: .text, text: "remove"))
        store.clearUnpinned()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items.first!.isPinned)
    }

    func test_moveToTop_bumps_reused_item_to_front() {
        store.add(ClipboardItem(type: .text, text: "a"))
        store.add(ClipboardItem(type: .text, text: "b"))
        store.add(ClipboardItem(type: .text, text: "c"))
        let a = store.items.first { $0.text == "a" }!

        store.moveToTop(a)

        XCTAssertEqual(store.items.first?.text, "a")
        XCTAssertEqual(store.filteredItems.first?.text, "a")
    }

    func test_pruneExpired_removes_old_unpinned_keeps_pinned_and_recent() {
        UserDefaults.standard.set(1, forKey: "keepHistoryIndex")
        defer { UserDefaults.standard.removeObject(forKey: "keepHistoryIndex") }

        let old    = Date().addingTimeInterval(-8 * 86_400)
        let recent = Date().addingTimeInterval(-1 * 86_400)

        store.add(ClipboardItem(type: .text, text: "old-pinned", timestamp: old, isPinned: true))
        store.add(ClipboardItem(type: .text, text: "old-unpinned", timestamp: old))
        store.add(ClipboardItem(type: .text, text: "recent", timestamp: recent))

        store.pruneExpired()

        XCTAssertFalse(store.items.contains { $0.text == "old-unpinned" })
        XCTAssertTrue(store.items.contains { $0.text == "old-pinned" })
        XCTAssertTrue(store.items.contains { $0.text == "recent" })
    }

    func test_pruneExpired_forever_keeps_everything() {
        UserDefaults.standard.set(4, forKey: "keepHistoryIndex")
        defer { UserDefaults.standard.removeObject(forKey: "keepHistoryIndex") }

        store.add(ClipboardItem(type: .text, text: "ancient",
                                timestamp: Date().addingTimeInterval(-1000 * 86_400)))
        store.pruneExpired()

        XCTAssertTrue(store.items.contains { $0.text == "ancient" })
    }

    func test_setLabel_names_and_clears() {
        let item = ClipboardItem(type: .text, text: "1234")
        store.add(item)

        store.setLabel("  Bank account  ", for: item.id)
        XCTAssertEqual(store.items.first?.label, "Bank account")

        store.setLabel("   ", for: item.id)
        XCTAssertNil(store.items.first?.label)
    }

    func test_filteredItems_matches_label() {
        let item = ClipboardItem(type: .text, text: "1234")
        store.add(item)
        store.setLabel("Bank account", for: item.id)
        store.searchQuery = "bank"

        XCTAssertEqual(store.filteredItems.count, 1)
    }

    func test_filteredItems_type_filter_token() {
        store.add(ClipboardItem(type: .text, text: "some text"))
        store.add(ClipboardItem(type: .image, imageData: Data([1, 2, 3])))
        store.searchQuery = "img:"

        XCTAssertEqual(store.filteredItems.count, 1)
        XCTAssertEqual(store.filteredItems.first?.type, .image)
    }

    func test_filteredItems_app_filter_token() {
        store.add(ClipboardItem(type: .text, text: "a", sourceAppBundleID: "com.google.Chrome"))
        store.add(ClipboardItem(type: .text, text: "b", sourceAppBundleID: "com.apple.Terminal"))
        store.searchQuery = "app:chrome"

        XCTAssertEqual(store.filteredItems.count, 1)
        XCTAssertEqual(store.filteredItems.first?.text, "a")
    }

    func test_setOCRText_makes_image_searchable_and_marks_it_scanned() {
        let image = ClipboardItem(type: .image, imageData: Data([1, 2, 3]))
        store.add(image)
        XCTAssertEqual(store.itemsAwaitingOCR().count, 1)

        store.setOCRText("Invoice 2026", for: image.id)
        store.searchQuery = "invoice"

        XCTAssertEqual(store.filteredItems.count, 1)
        XCTAssertTrue(store.itemsAwaitingOCR().isEmpty)
    }

    func test_setOCRText_empty_still_marks_scanned() {
        let image = ClipboardItem(type: .image, imageData: Data([9]))
        store.add(image)
        store.setOCRText("", for: image.id)

        XCTAssertTrue(store.itemsAwaitingOCR().isEmpty)
    }

    func test_persistence_roundtrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_clipboard_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writeStore = ClipboardStore(maxItems: 10, storageDir: tempDir)
        writeStore.add(ClipboardItem(type: .text, text: "persist me", isPinned: true))

        let expectation = expectation(description: "background save")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        let readStore = ClipboardStore(maxItems: 10, storageDir: tempDir)
        XCTAssertEqual(readStore.items.first?.text, "persist me")
        XCTAssertTrue(readStore.items.first!.isPinned)
    }
}
