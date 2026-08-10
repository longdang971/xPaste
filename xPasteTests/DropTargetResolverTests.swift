import XCTest
@testable import xPaste

/// Choosing the application a drag was released over.
final class DropTargetResolverTests: XCTestCase {

    private func window(_ pid: pid_t, _ rect: CGRect, layer: Int = 0) -> DropTargetResolver.Window {
        DropTargetResolver.Window(pid: pid, bounds: rect, layer: layer)
    }

    /// The window list arrives front to back, so the first window containing the point is the one on
    /// top — the one the user was actually pointing at.
    func testTheFrontmostWindowUnderThePointWins() {
        let front = window(11, CGRect(x: 0, y: 0, width: 500, height: 500))
        let behind = window(22, CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10),
                                                in: [front, behind], excluding: 99), 11)
    }

    func testWindowsThatDoNotContainThePointAreSkipped() {
        let left = window(11, CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = window(22, CGRect(x: 200, y: 0, width: 100, height: 100))
        XCTAssertEqual(DropTargetResolver.owner(of: CGPoint(x: 250, y: 50),
                                                in: [left, right], excluding: 99), 22)
    }

    /// xPaste's own windows are never the target: the panel is what the item was dragged out of.
    func testOurOwnWindowsAreIgnored() {
        let ours = window(42, CGRect(x: 0, y: 0, width: 500, height: 500))
        let theirs = window(11, CGRect(x: 0, y: 0, width: 500, height: 500))
        XCTAssertEqual(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10),
                                                in: [ours, theirs], excluding: 42), 11)
    }

    /// The menu bar, the Dock and every other piece of system furniture sits above the ordinary
    /// window layer. Releasing over one means "no application", not "paste into the Dock".
    func testWindowsAboveTheOrdinaryLayerAreIgnored() {
        let dock = window(33, CGRect(x: 0, y: 0, width: 500, height: 500), layer: 20)
        XCTAssertNil(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10),
                                              in: [dock], excluding: 99))
    }

    func testNothingUnderThePointIsNoTarget() {
        XCTAssertNil(DropTargetResolver.owner(of: CGPoint(x: 10, y: 10), in: [], excluding: 99))
    }

    /// A dragging session reports a bottom-left origin and the window list uses top-left, both
    /// measured against the primary display. Getting the flip backwards would resolve every drop to
    /// whatever sits at the mirror image of the release point.
    func testTheScreenPointIsFlippedIntoWindowListSpace() {
        XCTAssertEqual(DropTargetResolver.flip(NSPoint(x: 300, y: 1290), primaryTop: 1440),
                       CGPoint(x: 300, y: 150))
        XCTAssertEqual(DropTargetResolver.flip(NSPoint(x: 0, y: 0), primaryTop: 1440),
                       CGPoint(x: 0, y: 1440))
    }
}
