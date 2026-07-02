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

    func test_write_file_puts_path_as_plain_text() {
        let pb = makeBoard("file-paste")
        let item = ClipboardItem(
            type: .file,
            fileURLs: [URL(fileURLWithPath: "/Users/user/Desktop/report.pdf")]
        )

        item.write(to: pb)

        XCTAssertEqual(pb.string(forType: .string), "/Users/user/Desktop/report.pdf")
    }

    func test_write_file_also_keeps_file_reference_for_finder() {
        let pb = makeBoard("file-both")
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let item = ClipboardItem(type: .file, fileURLs: [url])

        item.write(to: pb)

        let readBack = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(readBack?.first?.path, url.path)      // Finder pastes the file
        XCTAssertEqual(pb.string(forType: .string), url.path) // text fields get the path
    }

    func test_write_multiple_files_joins_paths_by_newline() {
        let pb = makeBoard("file-paste-multi")
        let item = ClipboardItem(
            type: .file,
            fileURLs: [
                URL(fileURLWithPath: "/Users/user/a.txt"),
                URL(fileURLWithPath: "/Users/user/b.txt"),
            ]
        )

        item.write(to: pb)

        XCTAssertEqual(pb.string(forType: .string), "/Users/user/a.txt\n/Users/user/b.txt")
    }

    private func fileURLItem(_ path: String) -> NSPasteboardItem {
        let pbItem = NSPasteboardItem()
        pbItem.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return pbItem
    }

    func test_from_directory_url_classifies_as_folder() {
        let pb = makeBoard("folder")
        pb.writeObjects([fileURLItem("/System/Library")])

        let item = ClipboardItem.from(pasteboard: pb)

        XCTAssertEqual(item?.type, .folder)
    }

    func test_from_regular_file_url_classifies_as_file() {
        let pb = makeBoard("regfile")
        pb.writeObjects([fileURLItem("/bin/zsh")])

        let item = ClipboardItem.from(pasteboard: pb)

        XCTAssertEqual(item?.type, .file)
    }

    func test_from_app_bundle_classifies_as_file_not_folder() {
        let pb = makeBoard("bundle")
        pb.writeObjects([fileURLItem("/System/Library/CoreServices/Finder.app")])

        let item = ClipboardItem.from(pasteboard: pb)

        XCTAssertEqual(item?.type, .file) // bundles look like single files to the user
    }

    func test_from_mixed_file_and_folder_classifies_as_file() {
        let pb = makeBoard("mixed")
        pb.writeObjects([fileURLItem("/System/Library"), fileURLItem("/bin/zsh")])

        let item = ClipboardItem.from(pasteboard: pb)

        XCTAssertEqual(item?.type, .file)
    }

    func test_displayText_folder_shows_folder_name() {
        let item = ClipboardItem(
            type: .folder,
            fileURLs: [URL(fileURLWithPath: "/Users/user/Documents")]
        )
        XCTAssertEqual(item.displayText, "Documents")
    }

    func test_write_folder_keeps_path_and_file_reference() {
        let pb = makeBoard("folder-write")
        let url = URL(fileURLWithPath: "/System/Library")
        let item = ClipboardItem(type: .folder, fileURLs: [url])

        item.write(to: pb)

        XCTAssertEqual(pb.string(forType: .string), url.path)
        let readBack = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(readBack?.first?.path, url.path)
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
