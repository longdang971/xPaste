import XCTest
import AppKit
@testable import xPaste

/// How large a logo is drawn on a card.
///
/// The card used to draw every one at 72pt. A favicon is very often 32 pixels, so a link to Google
/// Drive stretched 32 pixels across the 144 device ones a 72pt plate spends on a 2x display, and
/// the mark came out soft.
final class FaviconSizeTests: XCTestCase {
    func test_a_small_icon_is_drawn_small_rather_than_stretched() {
        XCTAssertEqual(ClipboardItemCard.logoSide(forPixelWidth: 32), 32)
        XCTAssertEqual(ClipboardItemCard.logoSide(forPixelWidth: 64), 64)
    }

    /// At most a 2x upscale: P points spend 2P device pixels, so P may not exceed the icon's width.
    func test_no_icon_is_drawn_more_than_twice_its_pixels() {
        for pixels in [20, 32, 48, 64, 72, 128, 512] {
            let side = ClipboardItemCard.logoSide(forPixelWidth: pixels)
            guard pixels >= Int(ClipboardItemCard.logoMinSide) else { continue }
            XCTAssertLessThanOrEqual(side, CGFloat(pixels), "\(pixels)px")
        }
    }

    func test_a_big_icon_still_fills_the_plate() {
        XCTAssertEqual(ClipboardItemCard.logoSide(forPixelWidth: 128),
                       ClipboardItemCard.logoMaxSide)
        XCTAssertEqual(ClipboardItemCard.logoSide(forPixelWidth: 512),
                       ClipboardItemCard.logoMaxSide)
    }

    /// There is no drawing a 16-pixel icon sharply. Small and centred is the least bad of it — but
    /// not so small it reads as a speck on an otherwise empty card.
    func test_a_tiny_icon_keeps_a_floor() {
        XCTAssertEqual(ClipboardItemCard.logoSide(forPixelWidth: 16),
                       ClipboardItemCard.logoMinSide)
    }

    /// An image with no readable bitmap — the same case `isLogoSized` already treats as a logo —
    /// gets the plate rather than the floor, because nothing is known to argue otherwise.
    func test_an_unmeasurable_image_gets_the_full_plate() {
        XCTAssertEqual(ClipboardItemCard.logoSide(forPixelWidth: nil),
                       ClipboardItemCard.logoMaxSide)
        XCTAssertEqual(ClipboardItemCard.logoSide(forPixelWidth: 0),
                       ClipboardItemCard.logoMaxSide)
    }
}
