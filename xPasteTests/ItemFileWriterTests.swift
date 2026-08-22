import XCTest
@testable import xPaste

/// Putting a `SaveFormat.Suggestion` on disk. The only part of saving that touches the filesystem,
/// so it is exercised against a real temporary directory rather than a stubbed one.
final class ItemFileWriterTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ItemFileWriterTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func suggestion(_ payload: SaveFormat.Payload,
                            ext: String = "txt") -> SaveFormat.Suggestion {
        SaveFormat.Suggestion(baseName: "item", ext: ext, payload: payload)
    }

    // MARK: - Payloads

    func testTextIsWrittenAsUTF8() throws {
        let target = url("note.txt")

        try ItemFileWriter.write(suggestion(.text("xin chào — ünïcode")), to: target)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "xin chào — ünïcode")
    }

    func testDataIsWrittenByteForByte() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let target = url("shot.jpg")

        try ItemFileWriter.write(suggestion(.data(bytes), ext: "jpg"), to: target)

        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    /// A page that never got fetched must not quietly produce a file. `resolving` is what turns a
    /// link into bytes, and skipping it is a programming mistake, not a save.
    func testAPageThatWasNeverFetchedIsNotWritten() {
        let target = url("page.html")
        let link = URL(string: "https://example.com/a")!

        XCTAssertThrowsError(try ItemFileWriter.write(suggestion(.remoteHTML(link), ext: "html"),
                                                      to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// Resolving a link fetches the document and hands back a suggestion that is plain bytes.
    /// Driven off a `file://` URL so the rule is checked without a network.
    func testResolvingALinkTurnsItIntoTheBytesOfThePage() async throws {
        let page = url("local.html")
        let markup = "<!DOCTYPE html><html><body><h1>hello</h1></body></html>"
        try Data(markup.utf8).write(to: page)

        let resolved = try await ItemFileWriter.resolving(
            suggestion(.remoteHTML(page), ext: "html"))

        XCTAssertEqual(resolved.payload, .data(Data(markup.utf8)))
        XCTAssertEqual(resolved.ext, "html")
    }

    func testAResolvedPageWritesTheMarkupItFetched() async throws {
        let page = url("local2.html")
        let markup = "<html><body>saved</body></html>"
        try Data(markup.utf8).write(to: page)
        let target = url("out.html")

        try ItemFileWriter.write(
            try await ItemFileWriter.resolving(suggestion(.remoteHTML(page), ext: "html")),
            to: target)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), markup)
    }

    func testAPageThatIsNotThereReportsTheFailure() async {
        let missing = url("nope.html")

        do {
            _ = try await ItemFileWriter.resolving(suggestion(.remoteHTML(missing), ext: "html"))
            XCTFail("expected a failure")
        } catch {
            // Any error will do; what matters is that nothing is written on a bad fetch.
        }
    }

    // MARK: - Nothing to write

    func testAnItemWithNothingLeftToWriteFailsInsteadOfLeavingAnEmptyFile() {
        let target = url("gone.png")

        XCTAssertThrowsError(try ItemFileWriter.write(suggestion(.unavailable, ext: "png"), to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// The dialog has already asked about replacing by this point, so the write has to actually
    /// replace — not fail, and not append to what was there.
    func testWritingOverAnExistingFileReplacesIt() throws {
        let target = url("note.txt")
        try Data("the old contents, which are longer".utf8).write(to: target)

        try ItemFileWriter.write(suggestion(.text("new")), to: target)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
    }

    func testWritingIntoADirectoryThatIsNotThereReportsTheFailure() {
        let target = directory.appendingPathComponent("nope/deeper/note.txt")

        XCTAssertThrowsError(try ItemFileWriter.write(suggestion(.text("hi")), to: target))
    }
}
