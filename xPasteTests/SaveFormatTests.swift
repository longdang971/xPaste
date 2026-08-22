import XCTest
import UniformTypeIdentifiers
@testable import xPaste

/// What "Save as File…" offers before the dialog opens: which extension the content looks like it
/// wants, what the file should be called, and what bytes go on disk.
///
/// Every rule here is a guess that can be wrong in a way nobody notices until they open the file,
/// which is exactly why the decision lives apart from the dialog and is checked directly.
final class SaveFormatTests: XCTestCase {

    private func text(_ s: String, label: String? = nil) -> ClipboardItem {
        ClipboardItem(type: .text, text: s, label: label)
    }
    private func link(_ s: String, label: String? = nil) -> ClipboardItem {
        ClipboardItem(type: .url, text: s, label: label)
    }
    private func image(_ bytes: Data = Data([1, 2, 3]), at date: Date = Date()) -> ClipboardItem {
        ClipboardItem(type: .image, imageData: bytes, timestamp: date)
    }

    private static let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])
    private static let jpegMagic = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0])

    // MARK: - Structure that can be parsed

    func testJSONIsRecognisedByParsingItRatherThanByItsBraces() {
        XCTAssertEqual(SaveFormat.textExtension(for: #"{"a": 1, "b": [2, 3]}"#), "json")
        XCTAssertEqual(SaveFormat.textExtension(for: #"[{"id": 1}]"#), "json")
    }

    func testSomethingThatMerelyStartsWithABraceIsNotJSON() {
        XCTAssertNotEqual(SaveFormat.textExtension(for: "{ not really json"), "json")
    }

    func testMarkupIsRecognisedFromItsOpeningTag() {
        XCTAssertEqual(SaveFormat.textExtension(for: "<?xml version=\"1.0\"?>\n<root/>"), "xml")
        XCTAssertEqual(SaveFormat.textExtension(for: "<!DOCTYPE html>\n<html><body>hi</body></html>"), "html")
        XCTAssertEqual(SaveFormat.textExtension(for: "<html lang=\"en\"><head></head></html>"), "html")
        XCTAssertEqual(SaveFormat.textExtension(for: "<svg viewBox=\"0 0 8 8\"><path/></svg>"), "svg")
    }

    // MARK: - Shebangs

    func testAShebangNamesTheLanguage() {
        XCTAssertEqual(SaveFormat.textExtension(for: "#!/usr/bin/env python3\nprint('hi')\n"), "py")
        XCTAssertEqual(SaveFormat.textExtension(for: "#!/bin/bash\necho hi\n"), "sh")
        XCTAssertEqual(SaveFormat.textExtension(for: "#!/bin/zsh\necho hi\n"), "sh")
        XCTAssertEqual(SaveFormat.textExtension(for: "#!/usr/bin/env node\nconsole.log(1)\n"), "js")
        XCTAssertEqual(SaveFormat.textExtension(for: "#!/usr/bin/env ruby\nputs 1\n"), "rb")
        XCTAssertEqual(SaveFormat.textExtension(for: "#!/usr/bin/perl\nprint 1;\n"), "pl")
    }

    /// The shebang is the author saying what this is, so it outranks a keyword that merely appears.
    func testAShebangBeatsALanguageMarkerFurtherDown() {
        let script = """
        #!/bin/bash
        # a helper that mentions function somewhere
        function greet() { echo hi; }
        greet
        """

        XCTAssertEqual(SaveFormat.textExtension(for: script), "sh")
    }

    func testAnUnknownInterpreterDoesNotResolveToShell() {
        XCTAssertNotEqual(SaveFormat.textExtension(for: "#!/usr/bin/env brainfuck\n++++."), "sh")
    }

    // MARK: - Language markers

    func testPHP() {
        let php = """
        <?php
        function slugify(string $title): string {
            return strtolower(trim($title));
        }
        """

        XCTAssertEqual(SaveFormat.textExtension(for: php), "php")
    }

    func testPython() {
        let py = """
        from dataclasses import dataclass

        def total(items):
            return sum(i.price for i in items)
        """

        XCTAssertEqual(SaveFormat.textExtension(for: py), "py")
    }

    func testSwift() {
        let swift = """
        import SwiftUI

        struct Badge: View {
            let count: Int
            var body: some View { Text("\\(count)") }
        }
        """

        XCTAssertEqual(SaveFormat.textExtension(for: swift), "swift")
    }

    func testSQL() {
        let sql = """
        SELECT id, name
        FROM users
        WHERE created_at > now() - interval '7 days';
        """

        XCTAssertEqual(SaveFormat.textExtension(for: sql), "sql")
        XCTAssertEqual(SaveFormat.textExtension(for: "create table t (id int);"), "sql")
    }

    func testGo() {
        let go = """
        package main

        import "fmt"

        func main() { fmt.Println("hi") }
        """

        XCTAssertEqual(SaveFormat.textExtension(for: go), "go")
    }

    func testRust() {
        XCTAssertEqual(SaveFormat.textExtension(for: "fn main() {\n    let mut n = 0;\n}"), "rs")
    }

    func testCAndCPlusPlus() {
        XCTAssertEqual(SaveFormat.textExtension(for: "#include <stdio.h>\nint main(void) { return 0; }"), "c")
        XCTAssertEqual(SaveFormat.textExtension(for: "#include <vector>\nstd::vector<int> v;"), "cpp")
    }

    func testJava() {
        let java = """
        public class Main {
            public static void main(String[] args) {
                System.out.println("hi");
            }
        }
        """

        XCTAssertEqual(SaveFormat.textExtension(for: java), "java")
    }

    func testJavaScript() {
        let js = """
        const fetchUser = async (id) => {
            const res = await fetch(`/users/${id}`);
            return res.json();
        };
        """

        XCTAssertEqual(SaveFormat.textExtension(for: js), "js")
    }

    func testTypeScriptIsToldApartFromJavaScriptByItsTypes() {
        let ts = """
        interface User { id: number; name: string }

        export const nameOf = (u: User): string => u.name;
        """

        XCTAssertEqual(SaveFormat.textExtension(for: ts), "ts")
    }

    func testCSS() {
        let css = """
        .card {
            border-radius: 14px;
            box-shadow: 0 4px 8px rgba(0, 0, 0, 0.22);
        }
        """

        XCTAssertEqual(SaveFormat.textExtension(for: css), "css")
    }

    func testMarkdown() {
        let md = """
        # Release notes

        See the [changelog](https://example.com/changes) for details.
        """

        XCTAssertEqual(SaveFormat.textExtension(for: md), "md")
    }

    /// A shell comment and a Markdown heading open the same way, so a heading alone is not enough.
    func testASingleHashLineIsNotMarkdown() {
        XCTAssertNotEqual(SaveFormat.textExtension(for: "# set up the machine\nmkdir -p /tmp/x"), "md")
    }

    func testCSV() {
        let csv = """
        name,email,city
        ada,ada@example.com,London
        alan,alan@example.com,Wilmslow
        """

        XCTAssertEqual(SaveFormat.textExtension(for: csv), "csv")
    }

    /// A response copied out of a browser's network tab is the commonest large JSON there is, and
    /// it is far past the window the language rules read. The parse has to see the whole document
    /// or every payload worth saving lands as `.txt`.
    func testALargeJSONPayloadIsStillJSON() {
        let rows = (0..<2000).map { #"{"id":\#($0),"name":"row \#($0)"}"# }.joined(separator: ",")

        XCTAssertEqual(SaveFormat.textExtension(for: "[\(rows)]"), "json")
    }

    /// Two lines that happen to break in the same places are not a spreadsheet — a note and a
    /// sign-off do that. Real rows are separated by bare commas; prose puts a space after each one.
    func testProseWithMatchingCommasIsNotASpreadsheet() {
        XCTAssertEqual(SaveFormat.textExtension(for: "Hello, Ada\nRegards, Alan"), "txt")
        XCTAssertEqual(SaveFormat.textExtension(for: "one, two, three\nfour, five, six"), "txt")
        XCTAssertEqual(SaveFormat.textExtension(for: "apples, pears\noranges, plums\nfigs, dates"), "txt")
    }

    // MARK: - Falling back

    func testProseIsPlainText() {
        let prose = """
        Remember to ask about the invoice, and to send the revised figures
        across before Friday.
        """

        XCTAssertEqual(SaveFormat.textExtension(for: prose), "txt")
    }

    func testALanguageWithNoRuleIsPlainTextRatherThanAGuess() {
        XCTAssertEqual(SaveFormat.textExtension(for: "10 PRINT \"HI\"\n20 GOTO 10"), "txt")
    }

    func testEmptyTextIsPlainText() {
        XCTAssertEqual(SaveFormat.textExtension(for: ""), "txt")
        XCTAssertEqual(SaveFormat.textExtension(for: "   \n\n  "), "txt")
    }

    // MARK: - Images

    /// The stored file is always named `.jpg`, whatever is actually in it — `compressedData`
    /// writes PNG for anything using its alpha channel. The bytes are the only evidence.
    func testTheImageExtensionComesFromTheBytesNotTheStoredName() {
        XCTAssertEqual(SaveFormat.imageExtension(for: Self.pngMagic), "png")
        XCTAssertEqual(SaveFormat.imageExtension(for: Self.jpegMagic), "jpg")
    }

    /// The dialog locks an image's extension by turning it into a `UTType`. If that lookup ever
    /// came back nil the lock would quietly stop happening and a `.png` holding JPEG would become
    /// possible again, so the extensions this produces are checked against it rather than assumed.
    func testEveryImageExtensionIsOneTheSystemCanResolve() {
        XCTAssertNotNil(UTType(filenameExtension: SaveFormat.imageExtension(for: Self.pngMagic)))
        XCTAssertNotNil(UTType(filenameExtension: SaveFormat.imageExtension(for: Self.jpegMagic)))
        XCTAssertNotNil(UTType(filenameExtension: SaveFormat.imageExtension(for: Data())))
    }

    func testUnrecognisedImageBytesDoNotCrash() {
        XCTAssertFalse(SaveFormat.imageExtension(for: Data()).isEmpty)
        XCTAssertFalse(SaveFormat.imageExtension(for: Data([0x01])).isEmpty)
    }

    // MARK: - Names

    func testANameTheUserGaveTheItemWinsOverAnythingDerived() {
        XCTAssertEqual(SaveFormat.baseName(for: text("def f(): pass", label: "my snippet")), "my snippet")
    }

    func testTextIsNamedAfterItsFirstMeaningfulLine() {
        XCTAssertEqual(SaveFormat.baseName(for: text("\n\n  hello world  \nsecond line")), "hello world")
    }

    func testALongFirstLineIsCutToSomethingAFinderWindowCanShow() {
        let name = SaveFormat.baseName(for: text(String(repeating: "a", count: 200)))

        XCTAssertEqual(name.count, 60)
    }

    func testCharactersAFileNameCannotHoldAreRemoved() {
        let name = SaveFormat.baseName(for: text("reports/2026: final"))

        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testALeadingDotIsStrippedSoTheFileIsNotHidden() {
        XCTAssertFalse(SaveFormat.baseName(for: text(".env values")).hasPrefix("."))
    }

    /// A file name is bounded in bytes, not in characters — 255 of them per path component. A flag
    /// is eight bytes, so sixty of them make a name the filesystem refuses outright, and the save
    /// fails at the last step, after the user has already chosen where to put it.
    func testANameIsBoundedInBytesNotJustCharacters() throws {
        let name = SaveFormat.baseName(for: text(String(repeating: "🇻🇳", count: 80)))

        XCTAssertLessThanOrEqual(name.utf8.count, 200, "this name cannot be written to disk")
        XCTAssertFalse(name.isEmpty)

        // Proven against a real filesystem rather than against the number alone.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("namebudget-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try Data("x".utf8).write(to: dir.appendingPathComponent(name + ".txt")))
    }

    /// Cutting by bytes must not slice a character in half.
    func testTrimmingToAByteBudgetKeepsWholeCharacters() {
        let name = SaveFormat.baseName(for: text(String(repeating: "🎉", count: 200)))

        XCTAssertFalse(name.contains("\u{FFFD}"))
        XCTAssertTrue(name.allSatisfy { $0 == "🎉" })
    }

    func testANameThatSanitisesToNothingFallsBackToClipboard() {
        XCTAssertEqual(SaveFormat.baseName(for: text("///")), "Clipboard")
        XCTAssertEqual(SaveFormat.baseName(for: text("   ")), "Clipboard")
    }

    func testABlankLabelDoesNotWin() {
        XCTAssertEqual(SaveFormat.baseName(for: text("hello", label: "   ")), "hello")
    }

    func testALinkIsNamedAfterItsHost() {
        XCTAssertEqual(SaveFormat.baseName(for: link("https://github.com/user/repo?x=1")), "github.com")
    }

    /// Matching how macOS names a screenshot, and readable whatever the machine's locale is.
    func testAnImageIsNamedAfterWhenItWasCopied() {
        let name = SaveFormat.baseName(for: image())

        XCTAssertNotNil(name.range(of: #"^Image \d{4}-\d{2}-\d{2} at \d{2}\.\d{2}\.\d{2}$"#,
                                   options: .regularExpression),
                        "unexpected image name: \(name)")
    }

    // MARK: - What is offered

    /// The menu entry and ⌘S have to agree about this, or one of them acts on a card the other
    /// says cannot be saved.
    func testOnlyContentWithNoFileOfItsOwnIsOfferedASave() {
        XCTAssertTrue(SaveFormat.canSave(.text))
        XCTAssertTrue(SaveFormat.canSave(.url))
        XCTAssertTrue(SaveFormat.canSave(.image))
    }

    /// A file item already is a file; dragging the card into Finder copies it. A second way to do
    /// the same thing is not a feature.
    func testFilesAndFoldersAreNotOfferedASave() {
        XCTAssertFalse(SaveFormat.canSave(.file))
        XCTAssertFalse(SaveFormat.canSave(.folder))
    }

    // MARK: - The suggestion as a whole

    func testATextItemSuggestsItsOwnTextAndAGuessedExtension() {
        let suggestion = SaveFormat.suggest(for: text("<?php echo 1;"))

        XCTAssertEqual(suggestion.ext, "php")
        XCTAssertEqual(suggestion.payload, .text("<?php echo 1;"))
    }

    func testTheFileNameJoinsTheNameAndTheExtension() {
        let suggestion = SaveFormat.suggest(for: text("hello", label: "note"))

        XCTAssertEqual(suggestion.fileName, "note.txt")
    }

    func testAnImageSuggestsTheBytesItWasHandedRatherThanReEncodingThem() {
        let bytes = Self.jpegMagic
        let suggestion = SaveFormat.suggest(for: image(bytes), imageBytes: bytes)

        XCTAssertEqual(suggestion.ext, "jpg")
        XCTAssertEqual(suggestion.payload, .data(bytes))
    }

    /// The item outlived its pixels — pruned, or the cache was cleared. Better to say so than to
    /// write an empty file the user only discovers is empty later.
    func testAnImageWithNoBytesLeftHasNothingToWrite() {
        XCTAssertEqual(SaveFormat.suggest(for: image(), imageBytes: nil).payload, .unavailable)
    }

    /// A link saves the page, not a pointer to it — so the bytes are not in hand yet and the
    /// payload names what still has to be fetched.
    func testALinkSuggestsThePageItPointsAt() {
        let suggestion = SaveFormat.suggest(for: link("https://example.com/a"))

        XCTAssertEqual(suggestion.ext, "html")
        XCTAssertEqual(suggestion.payload, .remoteHTML(URL(string: "https://example.com/a")!))
    }

    /// An item classified as a link whose text will not parse still has to save as something.
    func testAnUnparseableLinkFallsBackToText() {
        let suggestion = SaveFormat.suggest(for: link("not a url at all"))

        XCTAssertEqual(suggestion.ext, "txt")
        XCTAssertEqual(suggestion.payload, .text("not a url at all"))
    }
}

extension SaveFormatTests {

    // MARK: - What the dialog opens with

    /// Names taken from the content read badly far more often than they helped: a PHP snippet
    /// proposed itself as `<?php.php`. The dialog now offers the extension alone.
    func testTheDialogProposesTheExtensionAndNoName() {
        XCTAssertEqual(SaveFormat.suggest(for: text("<?php echo 1;")).dialogFileName, ".php")
        XCTAssertEqual(SaveFormat.suggest(for: text("just prose")).dialogFileName, ".txt")
        XCTAssertEqual(SaveFormat.suggest(for: link("https://example.com")).dialogFileName, ".html")
    }

    /// Even a name the user gave the item stays out of the dialog — they are about to type one.
    func testANamedItemStillOpensWithNoNameInTheDialog() {
        XCTAssertEqual(SaveFormat.suggest(for: text("hello", label: "note")).dialogFileName, ".txt")
    }

    /// A dragged file is a different matter: nobody is offered a field to type in, so it keeps the
    /// name it can work out.
    func testADraggedFileStillGetsADerivedName() {
        XCTAssertEqual(SaveFormat.suggest(for: text("hello", label: "note")).fileName, "note.txt")
    }

    // MARK: - Accepting the proposal untouched

    /// Saving `.php` as it stands would write a file with no name, hidden from the folder it was
    /// saved into.
    func testAProposalAcceptedUntouchedStillGetsAName() {
        let chosen = URL(fileURLWithPath: "/tmp/somewhere/.php")

        XCTAssertEqual(SaveFormat.ensuringName(chosen).lastPathComponent, "Clipboard.php")
    }

    func testANameTheUserTypedIsLeftAlone() {
        let chosen = URL(fileURLWithPath: "/tmp/somewhere/slugify.php")

        XCTAssertEqual(SaveFormat.ensuringName(chosen).lastPathComponent, "slugify.php")
    }

    /// A name that is only dots, or only spaces, is no name either.
    func testSomethingThatAmountsToNoNameGetsOne() {
        XCTAssertEqual(
            SaveFormat.ensuringName(URL(fileURLWithPath: "/tmp/x/...txt")).lastPathComponent,
            "Clipboard.txt")
        XCTAssertEqual(
            SaveFormat.ensuringName(URL(fileURLWithPath: "/tmp/x/ .md")).lastPathComponent,
            "Clipboard.md")
    }

    func testTheDirectoryTheUserChoseIsKept() {
        let chosen = URL(fileURLWithPath: "/tmp/deep/place/.json")

        XCTAssertEqual(SaveFormat.ensuringName(chosen).deletingLastPathComponent().path,
                       "/tmp/deep/place")
    }
}
