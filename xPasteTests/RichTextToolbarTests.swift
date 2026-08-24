import XCTest
@testable import xPaste

/// `RichTextToolbar.isLinkableAddress` in isolation.
///
/// The toolbar itself is a SwiftUI view with no XCTest target reaching it — there is no window to
/// drive a TextField or a caret through, and a test that built the view without one would assert
/// nothing about the reactive wiring this guards. The scheme check underneath it, though, is a pure
/// string-in/bool-out function, so it is pulled out and tested directly rather than left untested
/// alongside the view.
final class RichTextToolbarTests: XCTestCase {

    func test_http_and_https_are_linkable() {
        XCTAssertTrue(RichTextToolbar.isLinkableAddress("http://example.com"))
        XCTAssertTrue(RichTextToolbar.isLinkableAddress("https://example.com"))
    }

    func test_mailto_is_linkable() {
        XCTAssertTrue(RichTextToolbar.isLinkableAddress("mailto:someone@example.com"))
    }

    /// The precise thing this guard exists for: before the link row shipped there was no way to
    /// type an arbitrary address and have it become a `.link` run, and `javascript:`/`file:` must
    /// not open that door now.
    func test_javascript_and_file_schemes_are_rejected() {
        XCTAssertFalse(RichTextToolbar.isLinkableAddress("javascript:alert(1)"))
        XCTAssertFalse(RichTextToolbar.isLinkableAddress("file:///etc/passwd"))
    }

    func test_empty_and_schemeless_text_are_rejected() {
        XCTAssertFalse(RichTextToolbar.isLinkableAddress(""))
        XCTAssertFalse(RichTextToolbar.isLinkableAddress("not a url"))
    }

    func test_surrounding_whitespace_is_trimmed_before_checking() {
        XCTAssertTrue(RichTextToolbar.isLinkableAddress("  https://example.com  "))
    }
}
