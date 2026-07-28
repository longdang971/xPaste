import XCTest
@testable import xPaste

final class TextTransformTests: XCTestCase {

    func test_trim_removes_surrounding_whitespace() {
        XCTAssertEqual(TextTransform.trimWhitespace.apply(to: "  hello \n"), "hello")
    }

    func test_singleLine_joins_and_collapses_blank_lines() {
        XCTAssertEqual(TextTransform.singleLine.apply(to: "one\n\n  two  \nthree"), "one two three")
    }

    func test_singleLine_returns_nil_for_whitespace_only() {
        XCTAssertNil(TextTransform.singleLine.apply(to: "  \n\n "))
    }

    func test_case_transforms() {
        XCTAssertEqual(TextTransform.lowercase.apply(to: "MiXeD"), "mixed")
        XCTAssertEqual(TextTransform.uppercase.apply(to: "MiXeD"), "MIXED")
        XCTAssertEqual(TextTransform.capitalized.apply(to: "hello world"), "Hello World")
    }

    func test_prettyJSON_expands_compact_object() {
        let out = TextTransform.prettyJSON.apply(to: #"{"a":1}"#)

        XCTAssertNotNil(out)
        XCTAssertTrue(out!.contains("\n"))
        XCTAssertTrue(out!.contains("\"a\""))
    }

    func test_minifyJSON_strips_whitespace() {
        let out = TextTransform.minifyJSON.apply(to: "{\n  \"a\" : 1\n}")

        XCTAssertEqual(out, #"{"a":1}"#)
    }

    func test_prettyJSON_returns_nil_for_non_json() {
        XCTAssertNil(TextTransform.prettyJSON.apply(to: "just a sentence"))
        XCTAssertNil(TextTransform.prettyJSON.apply(to: "{ not really json"))
    }

    func test_prettyJSON_does_not_escape_slashes() {
        let out = TextTransform.prettyJSON.apply(to: #"{"u":"https://x.com/a"}"#)

        XCTAssertEqual(out?.contains(#"https://x.com/a"#), true)
    }

    func test_urlDecode_and_encode() {
        XCTAssertEqual(TextTransform.urlDecode.apply(to: "a%20b"), "a b")
        XCTAssertEqual(TextTransform.urlEncode.apply(to: "a b"), "a%20b")
    }

    func test_urlDecode_returns_nil_when_nothing_changes() {
        XCTAssertNil(TextTransform.urlDecode.apply(to: "plain"))
    }

    func test_domainOnly_extracts_host() {
        XCTAssertEqual(TextTransform.domainOnly.apply(to: "https://x.haiten.org/watch?v=1"), "x.haiten.org")
    }

    func test_domainOnly_returns_nil_for_plain_text() {
        XCTAssertNil(TextTransform.domainOnly.apply(to: "not a url at all"))
    }

    func test_applicable_offers_nothing_for_images() {
        XCTAssertTrue(TextTransform.applicable(to: "whatever", type: .image).isEmpty)
    }

    func test_applicable_drops_no_op_transforms() {
        let transforms = TextTransform.applicable(to: "already trimmed", type: .text)

        XCTAssertFalse(transforms.contains(.trimWhitespace))
        XCTAssertFalse(transforms.contains(.singleLine))
        XCTAssertTrue(transforms.contains(.uppercase))
    }

    func test_applicable_offers_json_for_json_text() {
        let transforms = TextTransform.applicable(to: #"{"a":1}"#, type: .text)

        XCTAssertTrue(transforms.contains(.prettyJSON))
    }

    func test_applicable_offers_domain_for_links() {
        let transforms = TextTransform.applicable(to: "https://example.com/page", type: .url)

        XCTAssertTrue(transforms.contains(.domainOnly))
    }
}
