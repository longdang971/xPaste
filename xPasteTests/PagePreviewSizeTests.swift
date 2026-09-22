import XCTest
import AppKit
@testable import xPaste

/// How big the preview popover is. One size for everything except a web page, which is the one
/// thing here laid out for a browser rather than for this window.
final class PagePreviewSizeTests: XCTestCase {
    private let big = CGSize(width: 2560, height: 1415)

    func test_a_roomy_screen_gets_the_full_page_size() {
        XCTAssertEqual(PreviewPopoverContent.pagePreviewSize(fitting: big),
                       PreviewPopoverContent.pagePreviewIdeal)
    }

    /// The panel runs along one edge of the screen and the popover is anchored to a card inside
    /// it, so a 13" laptop has nowhere to put the full height.
    func test_a_short_screen_gets_what_is_left_of_it() {
        let laptop = CGSize(width: 1512, height: 945)
        let size = PreviewPopoverContent.pagePreviewSize(fitting: laptop)
        XCTAssertEqual(size.height, 945 - 420)
        XCTAssertEqual(size.width, PreviewPopoverContent.pagePreviewIdeal.width)
    }

    /// Never smaller than every other preview: a screen too small for that is one the popover was
    /// already too big for, and shrinking further would only make the page harder to read.
    func test_it_never_shrinks_past_the_ordinary_preview() {
        let tiny = CGSize(width: 640, height: 480)
        let size = PreviewPopoverContent.pagePreviewSize(fitting: tiny)
        XCTAssertEqual(size.width, PreviewPopoverContent.defaultPreviewSize.width)
        XCTAssertEqual(size.height, PreviewPopoverContent.defaultPreviewSize.height)
    }

    /// No screen to measure against — the popover is being built before it has one — is the
    /// ordinary size, not a guess.
    func test_no_screen_means_the_ordinary_size() {
        XCTAssertEqual(PreviewPopoverContent.pagePreviewSize(fitting: nil),
                       PreviewPopoverContent.defaultPreviewSize)
    }

    /// The page is the only exception. Everything else is drawn at its own size inside the box, so
    /// a bigger box would only be emptier.
    func test_the_page_is_the_only_thing_that_grows() {
        XCTAssertGreaterThan(PreviewPopoverContent.pagePreviewIdeal.width,
                             PreviewPopoverContent.defaultPreviewSize.width)
        XCTAssertGreaterThan(PreviewPopoverContent.pagePreviewIdeal.height,
                             PreviewPopoverContent.defaultPreviewSize.height)
    }
}
