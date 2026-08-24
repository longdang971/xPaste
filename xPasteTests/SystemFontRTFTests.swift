import XCTest
import AppKit
@testable import xPaste

/// `NSAttributedString.rtf(from:documentAttributes:)` cannot name the system face and silently
/// substitutes Helvetica Neue into the font table — these are round-trip checks (encode through
/// `ItemEdit.rtf(from:)`, decode with `NSAttributedString(rtf:)`, inspect the resulting fonts) for
/// `SystemFontRTF.fixup`, which undoes that substitution, and for the two cases where it has to back
/// off rather than guess.
final class SystemFontRTFTests: XCTestCase {

    private let manager = NSFontManager.shared

    private func roundTrip(_ attributed: NSAttributedString) throws -> NSAttributedString {
        let data = try XCTUnwrap(ItemEdit.rtf(from: attributed))
        return try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
    }

    private func font(_ attributed: NSAttributedString, at index: Int) throws -> NSFont {
        try XCTUnwrap(attributed.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
    }

    /// The raw bytes `ItemEdit.rtf(from:)` would have produced before `SystemFontRTF.fixup` ran —
    /// what a refusal has to match exactly.
    private func unfixedRTF(_ attributed: NSAttributedString) throws -> Data {
        try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                                     documentAttributes: [:]))
    }

    // MARK: - The correctness bar

    /// The everyday case this exists for: a plain snippet with one word bolded through the
    /// toolbar (`NSFontManager.convert(_:toHaveTrait:)`, exactly as `RichTextCommand.bold` does it)
    /// must come back as the system face, not Helvetica Neue, with the bold intact.
    func testABoldWordInAPlainSnippetKeepsTheSystemFace() throws {
        let source = NSMutableAttributedString(string: "plain bold", attributes: ItemEdit.plainDefaults)
        let bold = manager.convert(ItemEdit.plainFont, toHaveTrait: .boldFontMask)
        source.addAttribute(.font, value: bold, range: NSRange(location: 6, length: 4))

        let restored = try roundTrip(source)

        let plainFont = try font(restored, at: 0)
        let boldFont = try font(restored, at: 6)
        XCTAssertTrue(RichTextHTML.isSystemFace(plainFont), "\(plainFont.fontName) is not the system face")
        XCTAssertTrue(RichTextHTML.isSystemFace(boldFont), "\(boldFont.fontName) is not the system face")
        XCTAssertFalse(manager.traits(of: plainFont).contains(.boldFontMask))
        XCTAssertTrue(manager.traits(of: boldFont).contains(.boldFontMask))
    }

    /// Regular, a bolded run and an italicised run write to a *single* font-table entry — the fixup
    /// has to key the rewrite on that shared, trait-stripped entry, not on each run's font as-is.
    func testRegularBoldAndItalicAllSurviveInOneAllSystemDocument() throws {
        let source = NSMutableAttributedString(string: "abc", attributes: ItemEdit.plainDefaults)
        let bold = manager.convert(ItemEdit.plainFont, toHaveTrait: .boldFontMask)
        let italic = manager.convert(ItemEdit.plainFont, toHaveTrait: .italicFontMask)
        source.addAttribute(.font, value: bold, range: NSRange(location: 1, length: 1))
        source.addAttribute(.font, value: italic, range: NSRange(location: 2, length: 1))

        let restored = try roundTrip(source)

        let regularFont = try font(restored, at: 0)
        let boldFont = try font(restored, at: 1)
        let italicFont = try font(restored, at: 2)
        for f in [regularFont, boldFont, italicFont] {
            XCTAssertTrue(RichTextHTML.isSystemFace(f), "\(f.fontName) is not the system face")
        }
        XCTAssertFalse(manager.traits(of: regularFont).contains(.boldFontMask))
        XCTAssertFalse(manager.traits(of: regularFont).contains(.italicFontMask))
        XCTAssertTrue(manager.traits(of: boldFont).contains(.boldFontMask))
        XCTAssertTrue(manager.traits(of: italicFont).contains(.italicFontMask))
    }

    /// Mixing the system face with a real named font must fix only the system entry — Times must
    /// come back exactly as it went in.
    func testMixingTheSystemFaceWithARealNamedFontLeavesTheNamedFontUntouched() throws {
        let times = try XCTUnwrap(NSFont(name: "Times New Roman", size: 13))
        let source = NSMutableAttributedString(string: "sys times", attributes: ItemEdit.plainDefaults)
        source.addAttribute(.font, value: times, range: NSRange(location: 4, length: 5))

        let restored = try roundTrip(source)

        let systemFont = try font(restored, at: 0)
        let timesFont = try font(restored, at: 4)
        XCTAssertTrue(RichTextHTML.isSystemFace(systemFont), "\(systemFont.fontName) is not the system face")
        XCTAssertEqual(timesFont.fontName, times.fontName, "the named font should not have moved at all")
    }

    // MARK: - Refusing rather than guessing

    /// A genuine Helvetica Neue run writes the identical table name a system run does, and a
    /// document holding both collapses onto the one entry. Renaming that entry would turn the real
    /// Helvetica Neue text into the system font too, so the fixup must leave the bytes exactly as
    /// they are — not just "close", the same bytes `rtf(from:)` would have produced on its own.
    func testAGenuineHelveticaNeueRunIsLeftExactlyAsItIsToday() throws {
        let helveticaNeue = try XCTUnwrap(NSFont(name: "HelveticaNeue", size: 13))
        let source = NSMutableAttributedString(string: "sys real", attributes: ItemEdit.plainDefaults)
        source.addAttribute(.font, value: helveticaNeue, range: NSRange(location: 4, length: 4))

        let fixed = try XCTUnwrap(ItemEdit.rtf(from: source))
        let unfixed = try unfixedRTF(source)

        XCTAssertEqual(fixed, unfixed, "an ambiguous rewrite must be refused, not guessed")
    }

    /// The writer names system medium and system semibold identically (`HelveticaNeue-Medium`), and
    /// reading that shared name back with a `\b` trait for the semibold run recovers medium, not
    /// semibold — there is no single entry that reads both weights back correctly, so the fixup must
    /// refuse rather than silently turn one weight into the other.
    func testSystemMediumAndSemiboldTogetherAreLeftExactlyAsTheyAreToday() throws {
        let medium = NSFont.systemFont(ofSize: 13, weight: .medium)
        let semibold = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let source = NSMutableAttributedString(string: "medium  semibold")
        source.addAttribute(.font, value: medium, range: NSRange(location: 0, length: 6))
        source.addAttribute(.font, value: semibold, range: NSRange(location: 8, length: 8))

        let fixed = try XCTUnwrap(ItemEdit.rtf(from: source))
        let unfixed = try unfixedRTF(source)

        XCTAssertEqual(fixed, unfixed, "an ambiguous rewrite must be refused, not guessed")
    }

    // MARK: - Never touching what never had the problem

    /// Nothing about an item that never contained the system face may change — same bytes as
    /// `rtf(from:)` would have produced without the fixup at all.
    func testAnItemThatNeverUsedTheSystemFaceIsByteForByteUnchanged() throws {
        let times = try XCTUnwrap(NSFont(name: "Times New Roman", size: 13))
        let source = NSAttributedString(string: "just times", attributes: [.font: times])

        let fixed = try XCTUnwrap(ItemEdit.rtf(from: source))
        let unfixed = try unfixedRTF(source)

        XCTAssertEqual(fixed, unfixed)
    }
}
