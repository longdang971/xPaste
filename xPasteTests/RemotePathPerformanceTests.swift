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

    /// The result is accumulated and returned, not discarded. `RemotePath.strip` is pure, so
    /// `_ = strip(x)` is dead code an optimising build is free to delete — and the test would then
    /// pass by measuring nothing at all.
    private func milliseconds(iterations: Int, _ body: () -> String?) -> (ms: Double, sink: Int) {
        var sink = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { sink &+= body()?.count ?? 1 }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(iterations)
        return (ms, sink)
    }

    /// Neither string can be a server path — the first characters settle it — so the big one must
    /// not cost meaningfully more than the small one. Splitting either into lines before reaching
    /// that verdict is what this exists to catch.
    func testRejectingLargeTextCostsNoMoreThanRejectingSmallText() {
        let small = prose(bytes: 4_000)
        let large = prose(bytes: 4_000_000)

        let smallRun = milliseconds(iterations: 200) { RemotePath.strip(small) }
        let largeRun = milliseconds(iterations: 200) { RemotePath.strip(large) }
        let (smallMs, largeMs) = (smallRun.ms, largeRun.ms)

        // Both are prose, so both must have been rejected — which is also what keeps the sink from
        // being optimised away.
        XCTAssertEqual(smallRun.sink, 200)
        XCTAssertEqual(largeRun.sink, 200)

        print("RemotePath.strip — 4KB of prose: \(smallMs)ms, 4MB of prose: \(largeMs)ms")

        // A thousandfold more text. Anything that walks it shows up here as a ratio in the
        // hundreds; an early-out keeps it near 1. The margin is wide enough not to be flaky.
        XCTAssertLessThan(largeMs, max(smallMs, 0.001) * 20)
    }
}

extension RemotePathPerformanceTests {

    /// The other side of the bound: a block that really is all remote URLs still gets parsed line
    /// by line, and `sizeLimit` is what decides how much of that the main thread can be asked to
    /// do in one poll. Measured at 22ms for the 5576 URLs the bound allows (Debug) — a one-off on
    /// a deliberate act of copying five thousand paths, which is what makes 256KB the right bound
    /// rather than a guess. This is the record of it.
    func testTheWorstCaseTheSizeBoundAllows() {
        // Just under 256KB of nothing but strippable URLs.
        let line = "sftp://10.0.0.5/home/pikalong/some/deep/folder"
        let count = (256 * 1024) / (line.utf8.count + 1) - 1
        let block = Array(repeating: line, count: count).joined(separator: "\n")
        XCTAssertLessThan(block.utf8.count, 256 * 1024)

        var sink = 0
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 { sink &+= RemotePath.strip(block)?.count ?? 0 }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / 20

        XCTAssertGreaterThan(sink, 0)
        print("RemotePath.strip — worst allowed block (\(count) URLs, \(block.utf8.count) bytes): \(ms)ms")
    }
}
