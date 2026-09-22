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

    /// A file pane lays out everything it shows — the picture, the icon and its facts, the list of
    /// names — so it takes the extra rather than leaving it as margin.
    func test_a_file_preview_is_a_tenth_larger_than_the_default() {
        XCTAssertEqual(PreviewPopoverContent.filePreviewSize, CGSize(width: 616, height: 506))
        XCTAssertEqual(PreviewPopoverContent.filePreviewScale, 1.1)
    }

    /// A colour swatch and a line of text are drawn at their own size inside the box, so for those
    /// a bigger box would only be emptier — they keep the default, and the page is the largest.
    func test_the_page_is_the_largest_of_the_three() {
        XCTAssertGreaterThan(PreviewPopoverContent.pagePreviewIdeal.width,
                             PreviewPopoverContent.defaultPreviewSize.width)
        XCTAssertGreaterThan(PreviewPopoverContent.pagePreviewIdeal.height,
                             PreviewPopoverContent.defaultPreviewSize.height)
    }
}
