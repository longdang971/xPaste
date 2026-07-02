import XCTest
@testable import xPaste

final class ClipboardItemTests: XCTestCase {

    private func makeBoard(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("test.\(name)"))
        pb.clearContents()
        return pb
    }

    func test_from_plain_text() {
        let pb = makeBoard("text")
        pb.setString("Hello world", forType: .string)

        let item = ClipboardItem.from(pasteboard: pb)

        XCTAssertEqual(item?.type, .text)
        XCTAssertEqual(item?.text, "Hello world")
    }

    func test_from_http_url_classifies_as_url() {
        let pb = makeBoard("url")
        pb.setString("https://apple.com", forType: .string)

        let item = ClipboardItem.from(pasteboard: pb)

        XCTAssertEqual(item?.type, .url)
        XCTAssertEqual(item?.text, "https://apple.com")
    }

    func test_from_empty_pasteboard_returns_nil() {
        let pb = makeBoard("empty")

        XCTAssertNil(ClipboardItem.from(pasteboard: pb))
    }

    func test_from_whitespace_only_returns_nil() {
        let pb = makeBoard("whitespace")
        pb.setString("   \n  ", forType: .string)

        XCTAssertNil(ClipboardItem.from(pasteboard: pb))
    }

    func test_from_prefers_file_url_over_attached_image_data() {
        let pb = makeBoard("file-with-icon")
        let fileURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let pbItem = NSPasteboardItem()
        pbItem.setString(fileURL.absoluteString, forType: .fileURL)
        if let tiff = NSWorkspace.shared.icon(forFile: fileURL.path).tiffRepresentation {
            pbItem.setData(tiff, forType: .tiff)
        }
        pb.writeObjects([pbItem])

        let item = ClipboardItem.from(pasteboard: pb)

        XCTAssertEqual(item?.type, .file)
        XCTAssertEqual(item?.fileURLs?.first?.lastPathComponent, "Finder.app")
    }

    func test_displayText_text_returns_text() {
        let item = ClipboardItem(type: .text, text: "Sample")
        XCTAssertEqual(item.displayText, "Sample")
    }

    func test_displayText_file_shows_filename() {
        let item = ClipboardItem(
            type: .file,
            fileURLs: [URL(fileURLWithPath: "/Users/user/Desktop/report.pdf")]
        )
        XCTAssertEqual(item.displayText, "report.pdf")
    }

    func test_displayText_image_uses_default_label() {
        let item = ClipboardItem(type: .image, imageData: Data())
        XCTAssertEqual(item.displayText, "Image")
    }

    func test_displayText_image_uses_custom_label() {
        let item = ClipboardItem(type: .image, imageData: Data(), label: "Screenshot")
        XCTAssertEqual(item.displayText, "Screenshot")
    }

    func test_codable_roundtrip_preserves_all_fields() throws {
        let item = ClipboardItem(
            type: .text,
            text: "Roundtrip",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            isPinned: true,
            label: "My label"
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

        XCTAssertEqual(decoded.id, item.id)
        XCTAssertEqual(decoded.text, item.text)
        XCTAssertEqual(decoded.isPinned, item.isPinned)
        XCTAssertEqual(decoded.label, item.label)
    }
}
