import XCTest
@testable import xPaste

/// What the stored payload costs on disk.
///
/// The payload is the cold half — it is not read to draw a card — so its size is not paid at
/// launch. It is paid by the history file, and by the external-blob file every payload past a few
/// kilobytes spills into. Text is what a clipboard mostly holds and text compresses well, so this
/// is close to free.
final class PayloadCompressionTests: XCTestCase {

    /// A log, which is what makes this worth doing: repetitive, large, and the thing people paste
    /// when they paste something big.
    private let log = String(repeating: "2026-08-30 06:50:00 [info] worker=7 status=ok\n",
                             count: 8000)

    private func payload(_ text: String) -> PasteboardPayload {
        PasteboardPayload(items: [.init(types: ["public.utf8-plain-text"],
                                        dataByType: ["public.utf8-plain-text": Data(text.utf8)])])
    }

    func testALargeTextPayloadIsStoredCompressed() throws {
        let raw = log.utf8.count
        XCTAssertGreaterThan(raw, 300_000, "the fixture stopped being large")

        let stored = try payload(log).encoded()

        XCTAssertLessThan(stored.count, raw / 4,
                          "a \(raw) byte log was stored as \(stored.count) bytes")
    }

    func testACompressedPayloadReadsBackByteForByte() throws {
        let stored = try payload(log).encoded()

        let restored = try XCTUnwrap(PasteboardPayload(decoding: stored))

        XCTAssertEqual(restored.data(forType: "public.utf8-plain-text"), Data(log.utf8))
    }

    /// Every representation, not just the one the card shows.
    func testACompressedPayloadKeepsEveryRepresentation() throws {
        let big = String(repeating: "<p>paragraph of marked up text</p>\n", count: 8000)
        let source = PasteboardPayload(items: [.init(
            types: ["public.html", "public.utf8-plain-text", "com.acme.private"],
            dataByType: ["public.html": Data(big.utf8),
                         "public.utf8-plain-text": Data(big.utf8),
                         "com.acme.private": Data([0x1, 0x2, 0x3])])])

        let restored = try XCTUnwrap(PasteboardPayload(decoding: try source.encoded()))

        XCTAssertEqual(restored.data(forType: "public.html"), Data(big.utf8))
        XCTAssertEqual(restored.data(forType: "public.utf8-plain-text"), Data(big.utf8))
        XCTAssertEqual(restored.data(forType: "com.acme.private"), Data([0x1, 0x2, 0x3]))
    }

    /// Already-compressed bytes do not shrink, and a container that grew them would be a container
    /// that costs something for nothing. The smallest items in a history are also the commonest.
    func testAPayloadThatWouldNotShrinkIsStoredPlain() throws {
        let stored = try payload("hi").encoded()

        XCTAssertEqual(stored.prefix(8), Data("bplist00".utf8),
                       "a two byte string was wrapped in a compression container")
    }

    /// A history written by the build before this one is a bare property list, and has to stay
    /// readable — the alternative is a launch that silently drops every payload in the store.
    func testAPayloadWrittenBeforeCompressionIsStillReadable() throws {
        let uncompressed = try PropertyListSerialization.data(
            fromPropertyList: [
                "v": 1,
                "items": [["types": ["public.utf8-plain-text"], "blobs": [0]]],
                "blobs": [Data("written by an older build".utf8)],
            ],
            format: .binary, options: 0)

        let restored = try XCTUnwrap(PasteboardPayload(decoding: uncompressed))

        XCTAssertEqual(restored.string, "written by an older build")
    }
}
