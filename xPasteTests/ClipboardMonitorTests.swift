import XCTest
import AppKit
@testable import xPaste

/// The handshake that keeps xPaste's own writes out of the history.
///
/// Every paste path puts something on the pasteboard and then has to tell the monitor that the
/// change is xPaste's own, or the poll captures it right back as a new item — under the app that
/// was frontmost at that moment, and without the name or the pin the original carried.
final class ClipboardMonitorTests: XCTestCase {

    /// A pasteboard of its own, so the tests never touch what the user has copied.
    private func scratchBoard(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("xPasteTests.monitor.\(name)"))
        pb.clearContents()
        return pb
    }

    func testWritingThroughTheMonitorClaimsTheChange() {
        let pb = scratchBoard("owned")
        let monitor = ClipboardMonitor(pasteboard: pb)

        monitor.writeOwned { board in
            board.clearContents()
            board.setString("dragged text", forType: .string)
        }

        XCTAssertTrue(monitor.ownsCurrentChange)
        XCTAssertEqual(pb.string(forType: .string), "dragged text")
    }

    /// Why `writeOwned` exists at all: claiming first claims the change *before* xPaste's own, and
    /// the write that follows is left looking like a copy someone else made.
    func testClaimingBeforeTheWriteLeavesTheWriteUnclaimed() {
        let pb = scratchBoard("unclaimed")
        let monitor = ClipboardMonitor(pasteboard: pb)

        monitor.markNextChangeAsOwn()
        pb.clearContents()
        pb.setString("dragged text", forType: .string)

        XCTAssertFalse(monitor.ownsCurrentChange)
    }

    /// A change made by anything other than xPaste is not claimed, which is what makes the poll
    /// pick real copies up.
    func testAChangeNobodyClaimedIsNotOwned() {
        let pb = scratchBoard("foreign")
        let monitor = ClipboardMonitor(pasteboard: pb)

        pb.clearContents()
        pb.setString("copied elsewhere", forType: .string)

        XCTAssertFalse(monitor.ownsCurrentChange)
    }
}
