import XCTest
import SwiftUI
@testable import xPaste

final class FilterPopoverTests: XCTestCase {

    private func store(_ items: [ClipboardItem]) -> ClipboardStore {
        let store = ClipboardStore(maxItems: 20, storageDir: nil)
        items.forEach { store.add($0) }
        return store
    }

    func test_present_lists_each_source_app_once() {
        let items = [
            ClipboardItem(type: .text, text: "a", sourceAppBundleID: "com.google.Chrome"),
            ClipboardItem(type: .text, text: "b", sourceAppBundleID: "com.google.Chrome"),
            ClipboardItem(type: .text, text: "c", sourceAppBundleID: "com.apple.Terminal"),
            ClipboardItem(type: .text, text: "d")
        ]

        let apps = FilterApp.present(in: items)

        XCTAssertEqual(Set(apps.map(\.bundleID)), ["com.google.Chrome", "com.apple.Terminal"])
    }

    /// The sheet used to be handed a snapshot of the app list taken in the filter button's tap
    /// handler. On the panel's first open SwiftUI built the sheet from a copy of the view made
    /// before that write landed, so the App section was missing until the panel was reopened.
    /// Holding a provider instead keeps a sheet built from a stale copy correct: it asks the
    /// store when it appears, by which point the history is there.
    func test_apps_are_resolved_when_the_sheet_appears_not_when_it_is_built() {
        let store = store([])
        let sheet = FilterPopover(filters: .constant(SearchFilters())) {
            FilterApp.present(in: store.items)
        }

        // Everything the sheet could have snapshotted at build time is empty.
        store.add(ClipboardItem(type: .text, text: "a", sourceAppBundleID: "com.google.Chrome"))

        XCTAssertEqual(sheet.appsInHistory().map(\.bundleID), ["com.google.Chrome"])
    }
}
