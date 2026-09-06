import XCTest
@testable import xPaste

/// What deciding "this is not a server path" costs.
///
/// `RemotePath.strip` runs on the main thread from `ClipboardMonitor.poll`, for every text copy
/// anyone makes — so the overwhelmingly common case is a large-ish piece of text that is not a
/// path at all, and finding that out must not depend on how much text there is.
///
/// Assertions are relative, in the manner of `HighlightBakePerformanceTests`: an absolute
/// millisecond threshold would fail on a loaded machine while saying nothing. The absolute figures
/// are printed for the record.
final class RemotePathPerformanceTests: XCTestCase {

    private func prose(bytes: Int) -> String {
        String(repeating: "the quick brown fox jumps over the lazy dog ", count: bytes / 44)
    }

    private func milliseconds(iterations: Int, _ body: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { body() }
        return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(iterations)
    }

    /// Neither string can be a server path — the first characters settle it — so the big one must
    /// not cost meaningfully more than the small one. Splitting either into lines before reaching
    /// that verdict is what this exists to catch.
    func testRejectingLargeTextCostsNoMoreThanRejectingSmallText() {
        let small = prose(bytes: 4_000)
        let large = prose(bytes: 4_000_000)

        let smallMs = milliseconds(iterations: 200) { _ = RemotePath.strip(small) }
        let largeMs = milliseconds(iterations: 200) { _ = RemotePath.strip(large) }

        print("RemotePath.strip — 4KB of prose: \(smallMs)ms, 4MB of prose: \(largeMs)ms")

        // A thousandfold more text. Anything that walks it shows up here as a ratio in the
        // hundreds; an early-out keeps it near 1. The margin is wide enough not to be flaky.
        XCTAssertLessThan(largeMs, max(smallMs, 0.001) * 20)
    }
}
