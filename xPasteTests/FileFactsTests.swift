import XCTest
import AppKit
@testable import xPaste

/// What the preview pane says under a file's icon, and in its footer, comes from `FileFacts.read`.
/// It is the one part of that pane that touches the filesystem, and the one part that can be
/// checked without a window.
final class FileFactsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileFactsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func test_a_folder_is_counted_not_measured() throws {
        let folder = root.appendingPathComponent("box")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try write("box/a.txt", Data("a".utf8))
        _ = try write("box/b.txt", Data("b".utf8))

        let facts = FileFacts.read(folder)
        XCTAssertEqual(facts.detail, "2 items")
        XCTAssertFalse(facts.isImage)
    }

    func test_a_folder_holding_one_thing_says_item_not_items() throws {
        let folder = root.appendingPathComponent("single")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try write("single/only.txt", Data("x".utf8))

        XCTAssertEqual(FileFacts.read(folder).detail, "1 item")
    }

    /// A package is a directory to the filesystem and an application to everyone else. Counting its
    /// contents reported "Application · 1 item" under Xcode.app — true of the folder, nonsense
    /// about the app, whose one child is `Contents`.
    func test_a_package_is_not_counted_like_a_folder() throws {
        let app = root.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let facts = FileFacts.read(app)
        XCTAssertEqual(facts.detail, "")
        XCTAssertFalse(facts.isImage)
    }

    /// The dimensions come out of the file's header, which is what lets the footer carry them
    /// before anything has decided to decode the picture.
    func test_a_picture_reports_its_pixels_and_its_size() throws {
        // Built as a bitmap of an exact pixel size, not by drawing into an `NSImage`: that route
        // goes through the screen's backing scale, so on a 2x display a 40x20 point image is
        // written out as an 80x40 picture — and pixels are what this reports.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = try write("swatch.png", png)

        let facts = FileFacts.read(url)
        XCTAssertTrue(facts.isImage)
        XCTAssertTrue(facts.detail.hasPrefix("40 × 20 · "), facts.detail)
    }

    func test_a_plain_file_reports_only_its_size() throws {
        let url = try write("notes.txt", Data(String(repeating: "x", count: 2048).utf8))
        let facts = FileFacts.read(url)
        XCTAssertFalse(facts.isImage)
        XCTAssertFalse(facts.detail.isEmpty)
        XCTAssertFalse(facts.detail.contains("×"))
    }

    /// The subtitle under the icon is kind and detail on one line — and just the kind when there is
    /// no detail, rather than a line that starts with a stray separator.
    func test_the_subtitle_drops_the_separator_when_there_is_nothing_to_separate() {
        XCTAssertEqual(FileFacts(kind: "Application", detail: "", isImage: false).subtitle,
                       "Application")
        XCTAssertEqual(FileFacts(kind: "Folder", detail: "3 items", isImage: false).subtitle,
                       "Folder · 3 items")
        XCTAssertEqual(FileFacts(kind: "", detail: "12 KB", isImage: false).subtitle, "12 KB")
    }
}
