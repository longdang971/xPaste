import XCTest
@testable import xPaste

/// What the dedup key costs and what it can tell apart.
///
/// The key lives on `ItemEntity`, which is the hot half of the schema and is indexed — so its size
/// is paid on every launch, in the row and again in the B-tree. These are the tests that keep it
/// from growing with the content it identifies.
final class ContentChecksumTests: XCTestCase {

    private func checksum(text: String) -> String {
        ClipboardItem.makeChecksum(type: .text, id: UUID(), text: text,
                                   imageHash: nil, fileURLs: nil)
    }

    /// A pasted log is the case that matters: the key must not be a second copy of it.
    func testTheChecksumStaysSmallHoweverLargeTheText() {
        let log = String(repeating: "2026-08-30 06:50:00 [info] worker ok\n", count: 10_000)
        XCTAssertGreaterThan(log.count, 300_000, "the fixture stopped being large")

        let key = checksum(text: log)

        XCTAssertLessThan(key.count, 100,
                          "the dedup key grew with the content it indexes — \(key.count) characters")
    }

    /// The point of a digest rather than the content itself: the hot row stops carrying what the
    /// payload already holds.
    func testTheChecksumDoesNotCarryTheContentItIdentifies() {
        let key = checksum(text: "correct horse battery staple")

        XCTAssertFalse(key.contains("correct horse battery staple"),
                       "the key is still the content with a prefix on it")
    }

    func testTheSameTextAlwaysGivesTheSameChecksum() {
        XCTAssertEqual(checksum(text: "hello"), checksum(text: "hello"))
    }

    func testDifferentTextsGiveDifferentChecksums() {
        XCTAssertNotEqual(checksum(text: "hello"), checksum(text: "hellp"))
    }

    /// A URL and a text that read the same are two different things to paste, and the type prefix
    /// is what keeps them apart. Hashing must not take it away.
    func testATextAndAURLWithTheSameStringAreNotTheSameItem() {
        let sameString = "https://example.com"
        let asText = ClipboardItem.makeChecksum(type: .text, id: UUID(), text: sameString,
                                                imageHash: nil, fileURLs: nil)
        let asURL = ClipboardItem.makeChecksum(type: .url, id: UUID(), text: sameString,
                                               imageHash: nil, fileURLs: nil)

        XCTAssertNotEqual(asText, asURL)
    }

    /// The old key was the byte count plus the first and last sixteen bytes. For a JPEG the first
    /// sixteen are the SOI and JFIF header — identical in everything the same encoder writes — so
    /// the key was really the length and the tail, and two pictures that share those were one
    /// item. Copying the second then lost it to the first.
    func testTwoImagesThatDifferOnlyInTheMiddleAreNotTheSameItem() {
        var first = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
                          0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x90])
        var second = first
        first.append(Data(repeating: 0xAA, count: 4096))
        second.append(Data(repeating: 0xBB, count: 4096))
        let tail = Data(repeating: 0x7F, count: 16)
        first.append(tail)
        second.append(tail)
        XCTAssertEqual(first.count, second.count, "the fixture stopped being a length collision")

        XCTAssertNotEqual(ClipboardItem.makeHash(first), ClipboardItem.makeHash(second),
                          "two different pictures share one dedup key")
    }

    func testTheImageHashStaysSmallHoweverLargeThePicture() {
        let picture = Data(repeating: 0x42, count: 8 * 1024 * 1024)

        XCTAssertLessThan(ClipboardItem.makeHash(picture).count, 100)
    }
}
