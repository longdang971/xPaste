import XCTest
@testable import xPaste

final class ExclusionRulesTests: XCTestCase {

    func test_plain_pattern_matches_case_insensitively() {
        XCTAssertTrue(ExclusionRules.shouldExclude("My SECRET token", patterns: ["secret"]))
    }

    func test_plain_pattern_does_not_match_unrelated_text() {
        XCTAssertFalse(ExclusionRules.shouldExclude("hello world", patterns: ["secret"]))
    }

    func test_regex_pattern_matches() {
        let patterns = [#"/sk-[A-Za-z0-9]{8,}/"#]

        XCTAssertTrue(ExclusionRules.shouldExclude("key: sk-ABCdef123456", patterns: patterns))
        XCTAssertFalse(ExclusionRules.shouldExclude("key: sk-short", patterns: patterns))
    }

    func test_invalid_regex_is_skipped_not_crashing() {
        XCTAssertFalse(ExclusionRules.shouldExclude("anything", patterns: ["/[unclosed/"]))
    }

    func test_any_pattern_matching_excludes() {
        XCTAssertTrue(ExclusionRules.shouldExclude("visa 4111111111111111",
                                                   patterns: ["nope", #"/\d{16}/"#]))
    }

    func test_empty_inputs() {
        XCTAssertFalse(ExclusionRules.shouldExclude("", patterns: ["a"]))
        XCTAssertFalse(ExclusionRules.shouldExclude("text", patterns: []))
        XCTAssertFalse(ExclusionRules.shouldExclude("text", patterns: ["   "]))
    }

    func test_isValid_accepts_plain_and_good_regex() {
        XCTAssertTrue(ExclusionRules.isValid("password"))
        XCTAssertTrue(ExclusionRules.isValid(#"/\d{16}/"#))
    }

    func test_isValid_rejects_blank_and_broken_regex() {
        XCTAssertFalse(ExclusionRules.isValid("  "))
        XCTAssertFalse(ExclusionRules.isValid("/[unclosed/"))
    }

    func test_storedPatterns_reads_defaults() {
        let defaults = UserDefaults(suiteName: "xPasteTests.exclusions")!
        defaults.removePersistentDomain(forName: "xPasteTests.exclusions")
        defaults.set(["token"], forKey: ExclusionRules.defaultsKey)
        defer { defaults.removePersistentDomain(forName: "xPasteTests.exclusions") }

        XCTAssertEqual(ExclusionRules.storedPatterns(defaults), ["token"])
    }
}
