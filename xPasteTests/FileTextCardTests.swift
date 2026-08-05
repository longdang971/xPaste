import XCTest
@testable import xPaste

/// Which item gets its file read for a text preview, and which keeps the document icon.
final class FileTextCardTests: XCTestCase {

    private let a = URL(fileURLWithPath: "/tmp/a.json")
    private let b = URL(fileURLWithPath: "/tmp/b.txt")

    private func source(_ type: ClipboardContentType, files: [URL]? = nil,
                        path: URL? = nil, isDir: Bool = false) -> URL? {
        ClipboardItemCard.fileTextSource(type: type, fileURLs: files,
                                         detectedPath: path, detectedIsDirectory: isDir)
    }

    func test_a_single_copied_file_is_read() {
        XCTAssertEqual(source(.file, files: [a]), a)
    }

    func test_several_copied_files_are_not_read() {
        // Showing the first file's contents for a three-file item is a wrong answer that looks
        // like a right one — there is nothing on the card saying which file you are reading.
        XCTAssertNil(source(.file, files: [a, b]))
        XCTAssertNil(source(.file, files: []))
        XCTAssertNil(source(.file, files: nil))
    }

    func test_a_path_typed_as_text_is_read() {
        // Copying a path as text already gets the file's icon and name; it gets the contents too.
        XCTAssertEqual(source(.text, path: a), a)
    }

    func test_folders_are_never_read() {
        XCTAssertNil(source(.folder, files: [a]))
        XCTAssertNil(source(.text, path: a, isDir: true),
                     "a path pointing at a directory has no contents to show")
    }

    func test_items_that_are_not_files_are_not_read() {
        XCTAssertNil(source(.text))
        XCTAssertNil(source(.url, path: a),
                     "a URL card is a link card even if its text happens to resolve to a path")
        XCTAssertNil(source(.image, files: [a]))
    }
}
