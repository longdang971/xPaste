import XCTest
@testable import xPaste

final class ColorParserTests: XCTestCase {

    func test_hex_forms() {
        XCTAssertNotNil(ColorParser.parse("#1e90ff"))
        XCTAssertNotNil(ColorParser.parse("#abc"))
        XCTAssertNotNil(ColorParser.parse("#1e90ff80"))
    }

    func test_hex_rejects_non_hex_digits() {
        XCTAssertNil(ColorParser.parse("#zzzzzz"))
        XCTAssertNil(ColorParser.parse("#12345"))
    }

    func test_rgb_and_hsl() {
        XCTAssertNotNil(ColorParser.parse("rgb(30, 144, 255)"))
        XCTAssertNotNil(ColorParser.parse("rgba(30,144,255,0.5)"))
        XCTAssertNotNil(ColorParser.parse("hsl(210, 100%, 56%)"))
    }

    func test_rgb_rejects_out_of_range_components() {
        XCTAssertNil(ColorParser.parse("rgb(300, 144, 255)"))
    }

    func test_surrounding_whitespace_is_ignored() {
        XCTAssertNotNil(ColorParser.parse("  #1e90ff \n"))
    }

    func test_plain_text_is_not_a_color() {
        XCTAssertNil(ColorParser.parse("hello world"))
        XCTAssertFalse(ColorParser.isColor("hello world"))
        XCTAssertFalse(ColorParser.isColor(nil))
    }

    func test_isColor_agrees_with_parse() {
        XCTAssertTrue(ColorParser.isColor("#1e90ff"))
    }
}
