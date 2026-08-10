import XCTest
import AppKit
@testable import xPaste

/// The geometry behind the panel's reveal.
///
/// The reveal is a Core Animation translate of the bar inside a window that never moves, so these
/// numbers are the whole contract: the window has to be big enough to hold the bar at both ends of
/// its journey, the bar has to start somewhere the user cannot see, and it has to end up exactly
/// where the panel is meant to sit. Getting any of them wrong is not a slow panel but a visibly
/// wrong one — a bar peeking over the Dock before it is meant to, or one that jumps on arrival.
final class PanelSlideGeometryTests: XCTestCase {

    /// A bottom-docked bar on a 1440-point-tall screen, floating the usual gap above the edge.
    private let bottomBar = NSRect(x: 8, y: 8, width: 2544, height: 324)
    /// The same bar docked to the left edge.
    private let leftBar = NSRect(x: 8, y: 8, width: 254, height: 1424)

    private func geometry(_ target: NSRect, _ position: String) -> PanelLayout.PanelSlideGeometry {
        PanelLayout.slideGeometry(for: target, position: position)
    }

    // MARK: - The bar ends up where the panel belongs

    /// `barFrame` is the bar's resting place in the window's own coordinates, so offsetting it by
    /// the window's origin has to land back on the frame the panel was asked for.
    func testRestingBarLandsOnTheTargetFrame() {
        for (target, position) in [(bottomBar, "bottom"), (bottomBar, "top"),
                                   (leftBar, "left"), (leftBar, "right")] {
            let geo = geometry(target, position)
            let onScreen = geo.barFrame.offsetBy(dx: geo.windowFrame.minX, dy: geo.windowFrame.minY)
            XCTAssertEqual(onScreen, target, "resting bar in the \(position) position")
        }
    }

    // MARK: - The window holds both ends of the journey

    func testWindowContainsTheBarAtBothEnds() {
        for (target, position) in [(bottomBar, "bottom"), (bottomBar, "top"),
                                   (leftBar, "left"), (leftBar, "right")] {
            let geo = geometry(target, position)
            let bounds = NSRect(origin: .zero, size: geo.windowFrame.size)
            XCTAssertTrue(bounds.contains(geo.barFrame),
                          "\(position): window must hold the arrived bar")
            XCTAssertTrue(bounds.contains(geo.displacedBarFrame),
                          "\(position): window must hold the parked bar, or it would be clipped "
                          + "into view early")
        }
    }

    // MARK: - The parked bar is out of sight

    /// Parked, the bar must be clear of its resting rect entirely — touching it, or stopping short,
    /// would leave a strip of the panel on screen before the reveal starts.
    func testParkedBarClearsItsRestingPlaceAltogether() {
        for (target, position) in [(bottomBar, "bottom"), (bottomBar, "top"),
                                   (leftBar, "left"), (leftBar, "right")] {
            let geo = geometry(target, position)
            XCTAssertFalse(geo.barFrame.intersects(geo.displacedBarFrame),
                           "\(position): the parked bar still overlaps where it will come to rest")
        }
    }

    /// The bar travels its own thickness plus the slack, which is what carries it past the gap it
    /// floats above the screen edge and takes its shadow with it.
    func testTravelIsThicknessPlusSlack() {
        let bottom = geometry(bottomBar, "bottom")
        XCTAssertEqual(bottom.offset.height, -(bottomBar.height + PanelLayout.slideSlack))
        XCTAssertEqual(bottom.offset.width, 0)

        let top = geometry(bottomBar, "top")
        XCTAssertEqual(top.offset.height, bottomBar.height + PanelLayout.slideSlack)
        XCTAssertEqual(top.offset.width, 0)

        let left = geometry(leftBar, "left")
        XCTAssertEqual(left.offset.width, -(leftBar.width + PanelLayout.slideSlack))
        XCTAssertEqual(left.offset.height, 0)

        let right = geometry(leftBar, "right")
        XCTAssertEqual(right.offset.width, leftBar.width + PanelLayout.slideSlack)
        XCTAssertEqual(right.offset.height, 0)
    }

    // MARK: - The runway points off the screen, not into it

    /// The window grows away from the edge the bar is docked to, so the runway hangs off the screen
    /// rather than reaching across it. A window that grew the other way would put the bar's parked
    /// position in the middle of the display.
    func testRunwayExtendsAwayFromTheDockedEdge() {
        let bottom = geometry(bottomBar, "bottom")
        XCTAssertLessThan(bottom.windowFrame.minY, bottomBar.minY, "bottom: runway must hang below")
        XCTAssertEqual(bottom.windowFrame.maxY, bottomBar.maxY, "bottom: top edge must not move")

        let top = geometry(bottomBar, "top")
        XCTAssertGreaterThan(top.windowFrame.maxY, bottomBar.maxY, "top: runway must reach above")
        XCTAssertEqual(top.windowFrame.minY, bottomBar.minY, "top: bottom edge must not move")

        let left = geometry(leftBar, "left")
        XCTAssertLessThan(left.windowFrame.minX, leftBar.minX, "left: runway must reach left")
        XCTAssertEqual(left.windowFrame.maxX, leftBar.maxX, "left: right edge must not move")

        let right = geometry(leftBar, "right")
        XCTAssertGreaterThan(right.windowFrame.maxX, leftBar.maxX, "right: runway must reach right")
        XCTAssertEqual(right.windowFrame.minX, leftBar.minX, "right: left edge must not move")
    }

    /// The bar keeps its own size throughout: the reveal moves it, and only moves it. A resize
    /// would re-lay the SwiftUI content out mid-animation, which is the cost this design exists to
    /// avoid entirely.
    func testTheBarIsNeverResized() {
        for (target, position) in [(bottomBar, "bottom"), (bottomBar, "top"),
                                   (leftBar, "left"), (leftBar, "right")] {
            let geo = geometry(target, position)
            XCTAssertEqual(geo.barFrame.size, target.size, "\(position): resting size")
            XCTAssertEqual(geo.displacedBarFrame.size, target.size, "\(position): parked size")
        }
    }

    /// An unknown stored position falls back to the bottom bar, the way the rest of the panel code
    /// treats it — `panelPosition` comes out of user defaults and may be anything.
    func testUnknownPositionIsTreatedAsBottom() {
        XCTAssertEqual(geometry(bottomBar, "sideways"), geometry(bottomBar, "bottom"))
    }
}
