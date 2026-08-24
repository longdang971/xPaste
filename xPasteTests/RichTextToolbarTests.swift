import XCTest
import AppKit
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

    // MARK: - Toolbar symbols
    //
    // The toolbar's controls are inline SwiftUI view builders with no XCTest target reaching
    // them (see the file comment above), so the symbol names are pulled out into `static let`s
    // the view actually draws from — see `RichTextToolbar.textColourSymbol` and
    // `.clearFormattingSymbol` — so these tests assert against the same value the running app
    // uses rather than a copy that could drift from it.

    /// Regression guard for the bug this fixes: the text-colour menu used to draw as `"textformat"`
    /// — the exact glyph the font and mode-toggle controls also use — so it read as a font control
    /// sitting in the middle of two other font controls, with nothing saying "colour".
    func test_text_colour_symbol_resolves_and_is_not_the_font_glyph() {
        XCTAssertNotNil(NSImage(systemSymbolName: RichTextToolbar.textColourSymbol,
                                 accessibilityDescription: nil),
                         "\(RichTextToolbar.textColourSymbol) must exist on macOS 13, this " +
                         "project's deployment target")
        XCTAssertNotEqual(RichTextToolbar.textColourSymbol, "textformat")
    }

    /// Regression guard: the clear-formatting button used to draw `"textformat.size.smaller"`,
    /// which literally means "make the text smaller" — the opposite of clearing formatting.
    func test_clear_formatting_symbol_resolves_and_is_not_the_size_smaller_glyph() {
        XCTAssertNotNil(NSImage(systemSymbolName: RichTextToolbar.clearFormattingSymbol,
                                 accessibilityDescription: nil),
                         "\(RichTextToolbar.clearFormattingSymbol) must exist on macOS 13, this " +
                         "project's deployment target")
        XCTAssertNotEqual(RichTextToolbar.clearFormattingSymbol, "textformat.size.smaller")
    }
}
