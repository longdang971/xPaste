import XCTest
import AppKit
@testable import xPaste

/// `og:image` is not always a cover picture. A Chrome Web Store listing hands back the
/// extension's own 128px icon under that tag, and a card that fills itself with one blurs a
/// 128-pixel logo across a 460-pixel rect. The card has to tell the two apart before it draws.
final class LinkPreviewCardTests: XCTestCase {

    /// An image with real pixel dimensions — `NSImage(size:)` alone has no representation, and
    /// the size the card reads comes off the bitmap, not off the points.
    private func bitmap(_ width: Int, _ height: Int) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    func test_a_small_og_image_is_treated_as_a_logo() {
        // The case in the screenshot: chromewebstore.google.com serves the extension's 128px icon.
        XCTAssertTrue(ClipboardItemCard.isLogoSized(bitmap(128, 128)),
                      "a 128px icon cannot fill a card without going soft")
        XCTAssertTrue(ClipboardItemCard.isLogoSized(bitmap(280, 150)),
                      "small wins on its own — the long edge is still under the threshold")
    }

    func test_a_square_og_image_is_treated_as_a_logo_at_any_size() {
        // Cover art is almost never square; app icons and avatars almost always are.
        XCTAssertTrue(ClipboardItemCard.isLogoSized(bitmap(1200, 1200)),
                      "a big square is a logo served large, not a cover picture")
        XCTAssertTrue(ClipboardItemCard.isLogoSized(bitmap(1000, 900)),
                      "near-square counts too — icons are not always exactly 1:1")
    }

    func test_a_large_wide_og_image_keeps_the_full_bleed_treatment() {
        XCTAssertFalse(ClipboardItemCard.isLogoSized(bitmap(1200, 630)),
                       "the standard og:image ratio is a cover picture and should fill the card")
        XCTAssertFalse(ClipboardItemCard.isLogoSized(bitmap(600, 200)),
                       "a wide banner is a cover picture even when it is not especially large")
        XCTAssertFalse(ClipboardItemCard.isLogoSized(bitmap(800, 1400)),
                       "tall photographs fill the card as well — the rule is about squareness")
    }

    // MARK: - URLs that point straight at a picture

    /// `String(data:encoding:.isoLatin1)` decodes *any* byte sequence, so a JPEG body sails past
    /// the HTML guard and gets handed to the `og:` regexes. Nothing matches, and the card ends up
    /// as a titleless link instead of the picture the URL actually names. The response's own
    /// content type is what tells the two apart.
    func test_an_image_content_type_is_recognised_as_a_direct_picture() {
        XCTAssertTrue(LinkPreviewService.isDirectImage(mimeType: "image/jpeg"))
        XCTAssertTrue(LinkPreviewService.isDirectImage(mimeType: "image/png"))
        XCTAssertTrue(LinkPreviewService.isDirectImage(mimeType: "image/svg+xml"))
        XCTAssertTrue(LinkPreviewService.isDirectImage(mimeType: "IMAGE/GIF"),
                      "header values are not case-normalised by every server")
    }

    func test_a_page_content_type_is_not_a_direct_picture() {
        XCTAssertFalse(LinkPreviewService.isDirectImage(mimeType: "text/html"))
        XCTAssertFalse(LinkPreviewService.isDirectImage(mimeType: "application/json"))
        XCTAssertFalse(LinkPreviewService.isDirectImage(mimeType: nil),
                       "a response with no content type is a page until proven otherwise")
        XCTAssertFalse(LinkPreviewService.isDirectImage(mimeType: "text/html; boundary=image/png"),
                       "the type has to start with image/, not merely mention it")
    }

    /// The card branches on this flag before it branches on size, so a picture that happens to be
    /// small or square is still drawn as a picture rather than parked on the logo plate.
    func test_link_previews_are_pages_unless_told_otherwise() {
        let page = LinkPreviewData(title: "t", imageURL: nil, image: nil, domain: "example.com")
        XCTAssertFalse(page.isDirectImage,
                       "scraped pages must keep the treatment they always had")
    }

    // MARK: - Which card an image link draws
    //
    // A link to a picture is drawn as an image card — chequerboard, pixel dimensions, no footer
    // strip — while the item underneath stays a URL, so pasting it still pastes the link. Both the
    // preview and the footer switch on this one function, so they cannot disagree about whether
    // there is a footer strip for the dimensions pill to sit in.

    private func imagePreview(direct: Bool, loaded: Bool) -> LinkPreviewData {
        LinkPreviewData(title: nil, imageURL: URL(string: "https://e.com/a.jpg"),
                        image: loaded ? bitmap(800, 600) : nil,
                        domain: "e.com", isDirectImage: direct)
    }

    func test_a_loaded_image_link_draws_the_image_card() {
        XCTAssertTrue(ClipboardItemCard.drawsAsImageCard(
            type: .url, linkPreviewEnabled: true, preview: imagePreview(direct: true, loaded: true)))
    }

    func test_an_image_link_keeps_the_link_card_until_the_picture_arrives() {
        // Metadata lands one assignment before the image does. Dropping the footer in that gap
        // would leave the card with no footer *and* no picture to fill the strip it vacated.
        XCTAssertFalse(ClipboardItemCard.drawsAsImageCard(
            type: .url, linkPreviewEnabled: true, preview: imagePreview(direct: true, loaded: false)))
    }

    func test_a_scraped_page_keeps_the_link_card() {
        XCTAssertFalse(ClipboardItemCard.drawsAsImageCard(
            type: .url, linkPreviewEnabled: true, preview: imagePreview(direct: false, loaded: true)),
                       "an og:image belongs to a page, and the page's title and URL still matter")
        XCTAssertFalse(ClipboardItemCard.drawsAsImageCard(
            type: .url, linkPreviewEnabled: true, preview: nil))
    }

    func test_nothing_but_a_url_with_previews_on_draws_the_image_card() {
        XCTAssertFalse(ClipboardItemCard.drawsAsImageCard(
            type: .url, linkPreviewEnabled: false, preview: imagePreview(direct: true, loaded: true)),
                       "previews switched off means no fetch ran — the flag is stale at best")
        XCTAssertFalse(ClipboardItemCard.drawsAsImageCard(
            type: .text, linkPreviewEnabled: true, preview: imagePreview(direct: true, loaded: true)))
        XCTAssertFalse(ClipboardItemCard.drawsAsImageCard(
            type: .image, linkPreviewEnabled: true, preview: imagePreview(direct: true, loaded: true)),
                       "a real image card gets there on its own, not through the link branch")
    }

    func test_an_unreadable_image_falls_back_to_the_logo_treatment() {
        // No representation means no pixel count. Drawing it small wastes some card; drawing it
        // large risks the blurred rectangle this rule exists to prevent, so the small side wins.
        XCTAssertTrue(ClipboardItemCard.isLogoSized(NSImage(size: NSSize(width: 64, height: 64))),
                      "an image with no bitmap to measure must not be stretched on a guess")
    }
}
