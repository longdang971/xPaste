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

/// What a URL card draws in its body when there is no picture to draw.
///
/// A link that resolves to nothing is still a link. Paste gives it the same placeholder plate it
/// gives a page with no `og:image`; this used to require metadata to have come back, so a dead URL
/// fell through to the plain-text branch and the card read as an ordinary text card — no plate, and
/// its text running on under the footer.
final class DeadLinkCardTests: XCTestCase {

    func test_a_url_that_resolved_to_nothing_still_gets_the_placeholder_plate() {
        XCTAssertTrue(ClipboardItemCard.drawsLinkBody(previewEnabled: true,
                                                      hasMetadata: false,
                                                      fetchFinished: true),
                      "a dead link fell through to the plain-text card")
    }

    func test_a_page_with_metadata_but_no_image_still_gets_the_plate() {
        XCTAssertTrue(ClipboardItemCard.drawsLinkBody(previewEnabled: true,
                                                      hasMetadata: true,
                                                      fetchFinished: true))
    }

    /// No flash of an empty plate before the fetch has been anywhere. Until it comes back the card
    /// shows the URL, which is the one thing it does know.
    func test_nothing_is_drawn_as_a_link_body_while_the_fetch_is_still_out() {
        XCTAssertFalse(ClipboardItemCard.drawsLinkBody(previewEnabled: true,
                                                       hasMetadata: false,
                                                       fetchFinished: false))
        XCTAssertFalse(ClipboardItemCard.drawsLinkBody(previewEnabled: true,
                                                       hasMetadata: true,
                                                       fetchFinished: false))
    }

    /// Paste draws a compass on the plate and nothing else — see the reference screenshot. The
    /// bundled `no_image` art is a crossed-out photograph with "No Preview" written under it, which
    /// reads as something having gone wrong rather than as "this is a link with nothing to show".
    ///
    /// The assertion that matters is that the name resolves: a symbol that does not exist on this
    /// system draws nothing at all, and an empty plate is the one outcome worse than the old art.
    func test_the_placeholder_glyph_resolves_to_a_symbol() {
        XCTAssertNotNil(NSImage(systemSymbolName: ClipboardItemCard.placeholderSymbolName,
                                accessibilityDescription: nil),
                        "the placeholder glyph does not resolve — the plate would draw empty")
    }

    func test_link_previews_turned_off_means_no_plate_at_all() {
        XCTAssertFalse(ClipboardItemCard.drawsLinkBody(previewEnabled: false,
                                                       hasMetadata: true,
                                                       fetchFinished: true),
                       "the setting is off and the card still drew a link body")
    }
}

/// What the strip along the bottom of a card says.
///
/// "35 characters" is true of a URL and useless about it — Paste puts the URL there instead, and
/// that is the one thing a link card's reader is looking for. The count stays for text, where the
/// length is the only thing a truncated preview cannot show.
final class CardFooterLabelTests: XCTestCase {

    private func url(_ text: String) -> ClipboardItem {
        ClipboardItem(type: .url, text: text)
    }

    func test_a_url_card_says_the_url_rather_than_counting_its_characters() {
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: url("https://example.org/second-link-777")),
                       "example.org/second-link-777")
    }

    /// The scheme is chrome, not information, and it costs the width the path needs.
    func test_the_scheme_is_dropped_whatever_it_is() {
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: url("http://example.org/a")), "example.org/a")
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: url("ftp://files.test/pub")), "files.test/pub")
    }

    /// A bare host reads better without the slash it was copied with.
    func test_a_trailing_slash_is_dropped() {
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: url("https://example.org/")), "example.org")
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: url("https://example.org")), "example.org")
    }

    /// The path is what distinguishes two links to the same site, so it is never the part that goes.
    func test_the_path_is_kept_in_full() {
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: url("https://a.test/one/two?x=1#frag")),
                       "a.test/one/two?x=1#frag")
    }

    func test_a_text_card_still_counts_its_characters() {
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: ClipboardItem(type: .text, text: "hello")),
                       "5 characters")
    }

    func test_a_file_card_still_counts_its_files() {
        let item = ClipboardItem(type: .file,
                                 fileURLs: [URL(fileURLWithPath: "/tmp/a"),
                                            URL(fileURLWithPath: "/tmp/b")])
        XCTAssertEqual(ClipboardItemCard.footerLabel(for: item), "2 files")
    }

    /// The taller footer a link with metadata gets has the URL on its second line, and it is the
    /// same URL in the same shape as the plain strip's — two link cards side by side, one with a
    /// title and one without, must not disagree about how a URL is written.
    func test_the_url_under_a_title_is_written_the_same_way() {
        XCTAssertEqual(ClipboardItemCard.urlFooterLabel("https://example.com/"), "example.com")
    }

    /// Paste hangs the URL off the left edge of the strip; a count it centres. The difference is
    /// what the text is: "35 characters" is a caption about the card and sits under its middle,
    /// while a URL is read left to right and truncates on the right, so it has to start where
    /// reading starts.
    func test_only_a_url_footer_is_hung_off_the_left_edge() {
        XCTAssertTrue(ClipboardItemCard.footerAlignsLeading(for: ClipboardItem(type: .url,
                                                                               text: "https://a.test/b")))
        XCTAssertFalse(ClipboardItemCard.footerAlignsLeading(for: ClipboardItem(type: .text,
                                                                                text: "hello")))
        XCTAssertFalse(ClipboardItemCard.footerAlignsLeading(for: ClipboardItem(type: .image)))
        XCTAssertFalse(ClipboardItemCard.footerAlignsLeading(for: ClipboardItem(type: .color,
                                                                                text: "#fff")))
    }

    /// A link footer carries a URL rather than a caption, and a URL uses the full width and the
    /// full line height — descenders, slashes and all. Two points of strip is what stops it
    /// sitting tight against the plate above it.
    func test_a_link_footer_is_two_points_taller_than_a_caption_strip() {
        XCTAssertEqual(ClipboardItemCard.footerHeight(for: ClipboardItem(type: .url,
                                                                         text: "https://a.test/b")),
                       PanelLayout.cardFooterHeight + 2)
        XCTAssertEqual(ClipboardItemCard.footerHeight(for: ClipboardItem(type: .text, text: "hi")),
                       PanelLayout.cardFooterHeight)
        XCTAssertEqual(ClipboardItemCard.footerHeight(for: ClipboardItem(type: .image)),
                       PanelLayout.cardFooterHeight)
    }

}

/// Asking for the https version of a link copied as plain http.
///
/// macOS refuses a plain-http request from an app with no ATS exception before it reaches the
/// network — `NSURLErrorDomain -1022`, measured — so a link copied as `http://…` got no preview at
/// all: no title, no picture, just the plate. Nearly every site with a title worth showing serves
/// it over https too, so asking for that costs one scheme and needs no exception.
final class SecureTwinTests: XCTestCase {

    private func twin(_ s: String) -> String {
        LinkPreviewService.secureTwin(of: URL(string: s)!).absoluteString
    }

    func test_an_http_url_is_asked_for_over_https() {
        XCTAssertEqual(twin("http://example.com/"), "https://example.com/")
    }

    /// The path, query and fragment are what name the page; only the scheme changes.
    func test_everything_after_the_scheme_is_left_alone() {
        XCTAssertEqual(twin("http://a.test/one/two?x=1&y=2#frag"), "https://a.test/one/two?x=1&y=2#frag")
    }

    func test_a_url_that_is_already_secure_is_untouched() {
        XCTAssertEqual(twin("https://example.com/a"), "https://example.com/a")
    }

    /// Nothing else is a page to scrape, and rewriting one would be a request the caller never made.
    func test_other_schemes_are_untouched() {
        XCTAssertEqual(twin("file:///tmp/x"), "file:///tmp/x")
        XCTAssertEqual(twin("ftp://files.test/pub"), "ftp://files.test/pub")
    }

    /// 80 is the http default written out. Over https it names a port nobody serves TLS on, so
    /// carrying it across turns a working request into a refused one.
    func test_the_default_http_port_is_dropped_rather_than_carried_across() {
        XCTAssertEqual(twin("http://example.com:80/a"), "https://example.com/a")
    }

    /// Any other port is part of the address and stays. If nothing serves TLS there the fetch
    /// fails and the card falls back to the plate, which is what it did before this existed.
    func test_a_non_default_port_is_kept() {
        XCTAssertEqual(twin("http://example.com:8080/a"), "https://example.com:8080/a")
    }

}

/// The two lines of the footer a link with a title gets.
final class LinkFooterTypeTests: XCTestCase {

    func test_the_url_line_is_eleven_point() {
        XCTAssertEqual(ClipboardItemCard.linkFooterURLFontSize, 11)
    }

    /// The URL is the second line and has to keep reading as one. Bumping it is fine; bumping it
    /// past the title would make the card argue with itself about which line is the heading.
    func test_the_url_line_stays_smaller_than_the_title_above_it() {
        XCTAssertLessThan(ClipboardItemCard.linkFooterURLFontSize,
                          ClipboardItemCard.linkFooterTitleFontSize)
    }
}

