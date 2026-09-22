import XCTest
@testable import xPaste

/// How much of a page the preview reads before looking for its title.
///
/// This was a flat 512KB prefix, and it is why every YouTube link had no title and no picture:
/// YouTube spends about 700KB on inline script before writing `<title>` and the `og:` tags, so
/// neither was ever in the slice being searched.
final class LinkHeadSliceTests: XCTestCase {
    private func page(headPadding: Int, closeHead: Bool = true, uppercase: Bool = false) -> Data {
        var html = "<html><head>"
        html += "<script>" + String(repeating: "x", count: headPadding) + "</script>"
        html += #"<meta property="og:title" content="The Title">"#
        if closeHead { html += uppercase ? "</HEAD>" : "</head>" }
        html += "<body>" + String(repeating: "y", count: 200_000) + "</body></html>"
        return Data(html.utf8)
    }

    func test_the_head_is_kept_whole_however_far_down_the_tags_are() {
        // Past the 512KB the prefix used to stop at, which is the YouTube case.
        let data = page(headPadding: 700_000)
        let slice = LinkPreviewService.headSlice(of: data)
        XCTAssertTrue(String(decoding: slice, as: UTF8.self).contains("og:title"))
    }

    /// And the body is not: a page with a small head must not cost what its body weighs.
    func test_the_body_is_left_out() {
        let data = page(headPadding: 100)
        let slice = LinkPreviewService.headSlice(of: data)
        XCTAssertLessThan(slice.count, 1_000)
        XCTAssertFalse(String(decoding: slice, as: UTF8.self).contains("<body>"))
    }

    func test_an_uppercase_close_tag_is_recognised() {
        let data = page(headPadding: 600_000, uppercase: true)
        XCTAssertTrue(String(decoding: LinkPreviewService.headSlice(of: data), as: UTF8.self)
            .contains("og:title"))
    }

    /// A document that never closes its head must not pull the whole of itself into a `String`.
    func test_a_document_with_no_head_is_still_bounded() {
        let data = Data(String(repeating: "z", count: 5_000_000).utf8)
        XCTAssertEqual(LinkPreviewService.headSlice(of: data).count, 2 * 1024 * 1024)
    }
}
