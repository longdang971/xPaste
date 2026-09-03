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

/// What each press of the filter button does to the sheet.
///
/// The button used to flip `showFilters` directly, and SwiftUI writes that flag back long after
/// the popover has gone — so a press landing in the gap flipped a still-true flag to false and
/// opened nothing. Every press has to land.
final class PanelFiltersTests: XCTestCase {

    private var sheet: PanelFilters { .shared }

    override func setUp() {
        super.setUp()
        sheet.close()
    }

    override func tearDown() {
        sheet.close()
        super.tearDown()
    }

    func test_the_button_opens_the_sheet() {
        sheet.toggle()
        XCTAssertTrue(sheet.isPresented)
    }

    func test_the_button_closes_the_sheet_it_opened() {
        sheet.toggle()
        sheet.toggle()
        XCTAssertFalse(sheet.isPresented)
    }

    func test_every_press_flips_the_sheet() {
        for press in 1...9 {
            sheet.toggle()
            XCTAssertEqual(sheet.isPresented, !press.isMultiple(of: 2), "press \(press) did not land")
        }
    }

    /// AppKit dismissing the sheet — a click outside, the search box folding away, the panel
    /// hiding — leaves the next press free to open it again.
    func test_a_press_after_an_outside_dismissal_opens_it_again() {
        sheet.toggle()
        sheet.close()
        sheet.toggle()
        XCTAssertTrue(sheet.isPresented)
    }

    func test_closing_a_sheet_that_is_already_shut_is_harmless() {
        sheet.close()
        sheet.close()
        XCTAssertFalse(sheet.isPresented)
    }
}
