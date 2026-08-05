import XCTest
@testable import xPaste

/// A copied file that turns out to be readable text shows its contents rather than the generic
/// document icon. What counts as "readable text" is decided from the bytes, so these are the tests
/// that decide which files preview and which do not.
final class TextFileReaderTests: XCTestCase {

    // MARK: - Telling text from binary

    func test_a_nul_byte_means_binary() {
        // Every format that is not text — PDF, zip, Office, images — carries NUL bytes early on.
        XCTAssertFalse(TextFileReader.isProbablyText(Data([0x68, 0x69, 0x00, 0x21])))
        XCTAssertFalse(TextFileReader.isProbablyText(Data([0x00])))
    }

    func test_ordinary_text_bytes_are_text() {
        XCTAssertTrue(TextFileReader.isProbablyText(Data("{\n  \"a\": 1\n}\n".utf8)))
        XCTAssertTrue(TextFileReader.isProbablyText(Data("Xin chào\ttab\r\n".utf8)),
                      "accents, tabs and CRLF are all ordinary text")
    }

    // MARK: - Decoding

    func test_valid_utf8_decodes_whole() {
        XCTAssertEqual(TextFileReader.decode(Data("dòng một\ndòng hai".utf8)), "dòng một\ndòng hai")
    }

    /// The reader stops at a byte count, not a character count, so the last character is regularly
    /// cut in half. Vietnamese is 2–3 bytes per accented character, so this is the common case, not
    /// an edge case — and `String(data:encoding:.utf8)` returns nil for the *whole* block when it
    /// happens, which would make previews fail seemingly at random.
    func test_a_character_cut_in_half_costs_only_that_character() {
        let full = Data("Tiếng Việt".utf8)
        for dropped in 1...3 {
            let cut = full.dropLast(dropped)
            let decoded = TextFileReader.decode(Data(cut))
            XCTAssertNotNil(decoded, "dropping \(dropped) trailing byte(s) must still decode")
            XCTAssertTrue("Tiếng Việt".hasPrefix(decoded ?? "x"),
                          "what decodes must be a prefix of the original, not mangled text")
            XCTAssertTrue((decoded ?? "").hasPrefix("Tiếng Vi"),
                          "only the cut character may be lost, not the rest of the line")
        }
    }

    func test_bytes_that_are_not_utf8_at_all_do_not_decode() {
        // Invalid in the middle, so trimming the tail cannot rescue it — that is the tell for a
        // file that merely happens to have no NUL bytes near the start.
        XCTAssertNil(TextFileReader.decode(Data([0x41, 0xFF, 0xFE, 0x42, 0x43, 0x44])))
    }

    // MARK: - Reading from disk

    private func write(_ data: Data, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileReaderTests-\(name)")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_reads_a_text_file() throws {
        let url = try write(Data("{\n  \"project_id\": \"xpaste\"\n}".utf8), name: "a.json")
        XCTAssertEqual(TextFileReader.read(url, maxBytes: 8192), "{\n  \"project_id\": \"xpaste\"\n}")
    }

    func test_reads_no_more_than_the_byte_budget() throws {
        let url = try write(Data(String(repeating: "a", count: 50_000).utf8), name: "big.txt")
        let text = TextFileReader.read(url, maxBytes: 1000)
        XCTAssertEqual(text?.count, 1000, "a huge log must not be pulled into memory whole")
    }

    func test_a_binary_file_reads_as_nothing() throws {
        let url = try write(Data([0x25, 0x50, 0x44, 0x46, 0x00, 0x01, 0x02]), name: "b.pdf")
        XCTAssertNil(TextFileReader.read(url, maxBytes: 8192))
    }

    func test_an_empty_file_reads_as_nothing() throws {
        // Nothing to show, so the card keeps the icon rather than drawing a blank rectangle.
        let url = try write(Data(), name: "empty.txt")
        XCTAssertNil(TextFileReader.read(url, maxBytes: 8192))
    }

    func test_a_missing_file_reads_as_nothing() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-file.txt")
        XCTAssertNil(TextFileReader.read(url, maxBytes: 8192))
    }

    func test_a_directory_reads_as_nothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextFileReaderTests-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(TextFileReader.read(url, maxBytes: 8192))
    }
}
