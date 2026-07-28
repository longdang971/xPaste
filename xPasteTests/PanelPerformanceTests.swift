import XCTest
import SwiftUI
import AppKit
@testable import xPaste

/// Timings for the panel's open path.
///
/// Deliberately written against only the APIs that existed before the feature batch, so the same
/// file can be dropped onto an older checkout for a like-for-like baseline.
final class PanelPerformanceTests: XCTestCase {

    private func makeItems(_ n: Int) -> [ClipboardItem] {
        (0..<n).map { i in
            switch i % 4 {
            case 0:
                return ClipboardItem(type: .text, text: "sample text item number \(i) " +
                                     String(repeating: "lorem ipsum ", count: 12),
                                     sourceAppBundleID: "com.apple.Terminal")
            case 1:
                return ClipboardItem(type: .url, text: "https://example.com/page/\(i)",
                                     sourceAppBundleID: "com.google.Chrome")
            case 2:
                return ClipboardItem(type: .file,
                                     fileURLs: [URL(fileURLWithPath: "/tmp/file-\(i).txt")],
                                     sourceAppBundleID: "com.apple.finder")
            case 3 where i % 8 == 3:
                // A big paste: a page of source, a log dump, an article. Every card body pass
                // touches its text, so this is where per-pass string work shows up.
                return ClipboardItem(type: .text,
                                     text: String(repeating: "func doSomething() { return 42 }\n", count: 1200),
                                     sourceAppBundleID: "com.apple.dt.Xcode")
            default:
                return ClipboardItem(type: .text, text: "#1e90ff",
                                     sourceAppBundleID: "com.apple.Terminal")
            }
        }
    }

    private func makeStore(_ n: Int) -> ClipboardStore {
        let store = ClipboardStore(maxItems: 3000, storageDir: nil)
        for item in makeItems(n) { store.add(item) }
        return store
    }

    private func report(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let best = sorted.first ?? 0
        let worst = sorted.last ?? 0
        print(String(format: "PERF %@: median %.2f ms (best %.2f, worst %.2f, n=%d)",
                     name, median, best, worst, samples.count))
    }

    /// Cost of building the panel's whole SwiftUI tree and laying it out — what `warmPanel()`
    /// pays at launch and what a cold open would pay without it.
    func test_perf_cold_tree_build_and_layout() {
        let store = makeStore(300)
        var samples: [Double] = []
        for _ in 0..<10 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let host = NSHostingView(rootView: ContentView().environmentObject(store))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 300)
            host.layoutSubtreeIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        report("cold tree build + layout", samples)
    }

    /// Cost of the republish that every panel open performs: `publishingSuppressed = false`
    /// flushes everything copied while the panel was hidden, then the tree re-lays out.
    func test_perf_republish_and_relayout() {
        let store = makeStore(300)
        let host = NSHostingView(rootView: ContentView().environmentObject(store))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 300)
        host.layoutSubtreeIfNeeded()

        var samples: [Double] = []
        for i in 0..<15 {
            store.publishingSuppressed = true
            store.add(ClipboardItem(type: .text, text: "copied while hidden \(i)"))
            let t0 = CFAbsoluteTimeGetCurrent()
            store.publishingSuppressed = false
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        report("republish + relayout", samples)
    }

    /// The list the panel renders on open. Pure model work, no SwiftUI.
    func test_perf_filteredItems_unfiltered() {
        let store = makeStore(1000)
        var samples: [Double] = []
        for _ in 0..<30 {
            store.searchQuery = "x"      // invalidate the cache
            store.searchQuery = ""
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = store.filteredItems
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        report("filteredItems (1000 items, no query)", samples)
    }

    func test_perf_filteredItems_with_query() {
        let store = makeStore(1000)
        var samples: [Double] = []
        for i in 0..<30 {
            store.searchQuery = ""
            store.searchQuery = "item number \(i % 7)"
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = store.filteredItems
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        report("filteredItems (1000 items, text query)", samples)
    }
}
