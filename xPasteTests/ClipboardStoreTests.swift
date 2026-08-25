import XCTest
import Combine
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

    /// Deliberately NOT a test of the cap, despite what it used to be called.
    ///
    /// `maxItems` clamps its own argument up to `ClipboardStore.minHistoryCount` (500), so the `5`
    /// this store was built with is 500 by the time `trim()` reads it — eight items never came near
    /// it and the assertion passed without a trim ever running. What this does check is still worth
    /// checking: adding a run of items leaves a pinned one alone. The cap itself is exercised in
    /// `HistoryCapTests`, which is the only place that can, because it takes 501 items to get there.
    func test_adding_many_items_leaves_a_pinned_one_alone() {
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

    /// `imageData` is not persisted, so a restored item never carries one — but an item added
    /// during the session used to keep its whole buffer in the array for as long as the app ran.
    /// Forty screenshots measured 36 MB, against a cap of 3000 items.
    func test_add_does_not_keep_image_bytes_in_memory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_imgmem_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let disked = ClipboardStore(maxItems: 10, storageDir: dir)
        let blob = Data(repeating: 0xAB, count: 64_000)

        disked.add(ClipboardItem(type: .image, imageData: blob))

        XCTAssertNil(disked.items.first?.imageData)

        // Dropped only because there is somewhere to read them back from — so check that there is.
        let written = expectation(description: "background save")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { written.fulfill() }
        wait(for: [written], timeout: 2)
        let id = try XCTUnwrap(disked.items.first?.id)
        let url = try XCTUnwrap(disked.imageURL(for: id))
        XCTAssertEqual(try Data(contentsOf: url), blob)
    }

    /// With nowhere to write them, the buffer in memory is the only copy there is — dropping it
    /// would lose the picture outright.
    func test_a_store_with_no_directory_keeps_the_bytes() {
        store.add(ClipboardItem(type: .image, imageData: Data(repeating: 0xAB, count: 1_000)))

        XCTAssertNotNil(store.items.first?.imageData)
    }

    /// What the bytes are replaced by has to be enough for everything that reads them: the size
    /// shown in the footer, and the hash `add` de-duplicates on.
    func test_dropping_the_bytes_keeps_what_the_rest_of_the_app_reads() {
        let blob = Data(repeating: 0xAB, count: 64_000)
        store.add(ClipboardItem(type: .image, imageData: blob))
        store.add(ClipboardItem(type: .image, imageData: blob))

        XCTAssertEqual(store.items.count, 1, "de-duplication stopped working without the buffer")
        XCTAssertEqual(store.items.first?.imageSize, 64_000)
        XCTAssertNotNil(store.items.first?.imageHash)
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

    // MARK: - Editing an item's content

    private func addedText(_ s: String) -> ClipboardItem {
        store.add(ClipboardItem(type: .text, text: s))
        return store.items[0]
    }

    func test_updateContent_replaces_the_text() {
        let item = addedText("teh typo")

        store.updateContent(id: item.id, text: "the typo", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.text, "the typo")
    }

    /// The card's `.task` is keyed on this. Without the bump it never re-runs, and the card keeps
    /// drawing the `@State` it built for the old content.
    func test_updateContent_bumps_the_revision() {
        let item = addedText("before")

        store.updateContent(id: item.id, text: "after", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.contentRevision, item.contentRevision + 1)
    }

    func test_updateContent_reclassifies_text_that_became_a_link() {
        let item = addedText("not a link yet")

        store.updateContent(id: item.id, text: "https://example.com", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.type, .url)
    }

    func test_updateContent_reclassifies_a_link_that_became_text() {
        store.add(ClipboardItem(type: .url, text: "https://example.com"))
        let item = store.items[0]

        store.updateContent(id: item.id, text: "just a note", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.type, .text)
    }

    /// The timestamp says when the content was copied, and editing is not copying. Moving the card
    /// to the front would also make a correction look like fresh history.
    func test_updateContent_leaves_the_timestamp_and_the_pin_alone() {
        var pinned = ClipboardItem(type: .text, text: "keep")
        pinned.isPinned = true
        store.add(pinned)
        let before = store.items[0]

        store.updateContent(id: before.id, text: "kept", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.timestamp, before.timestamp)
        XCTAssertTrue(store.items.first!.isPinned)
    }

    /// Deleting is a separate gesture with its own confirmation. A save that emptied the item would
    /// be a way to lose it by accident.
    func test_updateContent_refuses_an_empty_result() {
        let item = addedText("still here")

        store.updateContent(id: item.id, text: "   \n ", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.text, "still here")
    }

    func test_updateContent_refuses_anything_that_is_not_text_or_a_link() {
        store.add(ClipboardItem(type: .image, imageData: Data([1, 2, 3])))
        let item = store.items[0]

        store.updateContent(id: item.id, text: "hello", richData: nil, richType: nil)

        XCTAssertNil(store.items.first?.text)
    }

    func test_updateContent_ignores_an_id_it_does_not_hold() {
        _ = addedText("untouched")

        store.updateContent(id: UUID(), text: "hello", richData: nil, richType: nil)

        XCTAssertEqual(store.items.first?.text, "untouched")
    }

    func test_updateContent_stores_the_formatting_it_was_given() {
        let item = addedText("plain")
        let rtf = ItemEdit.rtf(from: NSAttributedString(string: "styled"))

        store.updateContent(id: item.id, text: "styled", richData: rtf, richType: ItemEdit.richType)

        XCTAssertEqual(store.items.first?.richData, rtf)
        XCTAssertEqual(store.items.first?.richType, ItemEdit.richType)
    }

    /// `items` carries willSet/didSet, so each assignment through the subscript is a separate
    /// `objectWillChange` — and every one of those is a full SwiftUI pass over the panel. Editing
    /// touched five fields and cost five of them.
    func test_updateContent_costs_one_invalidation_not_one_per_field() {
        store.add(ClipboardItem(type: .text, text: "before"))
        let id = store.items[0].id

        var invalidations = 0
        let subscription = store.objectWillChange.sink { _ in invalidations += 1 }
        store.updateContent(id: id, text: "after", richData: nil, richType: nil)
        subscription.cancel()

        XCTAssertEqual(invalidations, 1)
    }

    func test_updateContent_survives_a_reload_from_disk() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_edit_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writeStore = ClipboardStore(maxItems: 10, storageDir: tempDir)
        writeStore.add(ClipboardItem(type: .text, text: "before"))
        writeStore.updateContent(id: writeStore.items[0].id, text: "after",
                                 richData: nil, richType: nil)

        let saved = expectation(description: "background save")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { saved.fulfill() }
        wait(for: [saved], timeout: 2)

        let readStore = ClipboardStore(maxItems: 10, storageDir: tempDir)
        XCTAssertEqual(readStore.items.first?.text, "after")
        XCTAssertEqual(readStore.items.first?.contentRevision, 1)
    }
}
