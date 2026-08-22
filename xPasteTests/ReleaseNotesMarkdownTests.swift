import XCTest
@testable import xPaste

/// The markdown reader behind the "What's New" box. It only has to handle what this project's own
/// release notes contain — headings, lists, quoted blocks, fenced code and rules — so the tests are
/// written against exactly those.
final class ReleaseNotesMarkdownTests: XCTestCase {

    func testReadsHeadingsBulletsAndNumbers() {
        let blocks = ReleaseNotesMarkdown.parse("""
        ## Drag to paste

        - A real paste command
        1. First
        2. Second
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Drag to paste"),
            .bullet(indent: 0, text: "A real paste command"),
            .ordered(indent: 0, number: 1, text: "First"),
            .ordered(indent: 0, number: 2, text: "Second"),
        ])
    }

    /// Wrapped prose is one paragraph. Left as separate blocks it renders as though the notes had
    /// been broken across lines at random.
    func testConsecutiveProseLinesJoinIntoOneParagraph() {
        let blocks = ReleaseNotesMarkdown.parse("one line\nand its continuation\n\nsecond para")
        XCTAssertEqual(blocks, [
            .paragraph("one line and its continuation"),
            .paragraph("second para"),
        ])
    }

    /// These notes open with a `>` block that itself contains bullets. With the marker left in,
    /// the whole quote collapses into one paragraph with `>` running through the middle of it.
    func testQuotedLinesAreClassifiedLikeAnyOther() {
        let blocks = ReleaseNotesMarkdown.parse("> ## Heads up\n> - a point\n>\n> prose")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Heads up"),
            .bullet(indent: 0, text: "a point"),
            .paragraph("prose"),
        ])
    }

    func testFencedCodeIsKeptVerbatim() {
        let blocks = ReleaseNotesMarkdown.parse("```\n  ./build-release.sh\n```")
        XCTAssertEqual(blocks, [.code("  ./build-release.sh")])
    }

    /// A fence the author never closed must not swallow the rest of the notes.
    func testAnUnclosedFenceStillShowsItsContents() {
        XCTAssertEqual(ReleaseNotesMarkdown.parse("```\nstranded"), [.code("stranded")])
    }

    /// Rules are recognised before bullets — `***` and `---` both open with a bullet marker.
    func testRulesAreNotMistakenForBullets() {
        XCTAssertEqual(ReleaseNotesMarkdown.parse("a\n\n---\n\nb"),
                       [.paragraph("a"), .rule, .paragraph("b")])
        XCTAssertEqual(ReleaseNotesMarkdown.parse("a\n\n* * *\n\nb"),
                       [.paragraph("a"), .rule, .paragraph("b")])
    }

    /// A rule against the edge of the box separates nothing. These notes really do end with `---`.
    func testRulesAtEitherEndAreDropped() {
        XCTAssertEqual(ReleaseNotesMarkdown.parse("---\nbody\n\n---"), [.paragraph("body")])
    }

    func testRepeatedRulesCollapseToOne() {
        XCTAssertEqual(ReleaseNotesMarkdown.parse("a\n\n---\n___\n\nb"),
                       [.paragraph("a"), .rule, .paragraph("b")])
    }

    /// Nesting is measured in pairs of spaces and capped, so a deeply indented list cannot push
    /// its text out of the box.
    func testIndentIsMeasuredAndCapped() {
        XCTAssertEqual(ReleaseNotesMarkdown.parse("  - two spaces"),
                       [.bullet(indent: 1, text: "two spaces")])
        XCTAssertEqual(ReleaseNotesMarkdown.parse("            - very deep"),
                       [.bullet(indent: 3, text: "very deep")])
    }

    /// Inline markdown is left alone: the view hands it to `AttributedString`.
    func testInlineMarkupSurvivesUntouched() {
        XCTAssertEqual(ReleaseNotesMarkdown.parse("- a **bold** `bit`"),
                       [.bullet(indent: 0, text: "a **bold** `bit`")])
    }

    func testEmptyNotesProduceNoBlocks() {
        XCTAssertTrue(ReleaseNotesMarkdown.parse("").isEmpty)
        XCTAssertTrue(ReleaseNotesMarkdown.parse("\n\n  \n").isEmpty)
    }
}
