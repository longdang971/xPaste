import XCTest
@testable import xPaste

final class NotchGeometryTests: XCTestCase {
    /// A 14" MacBook Pro at its default resolution: 1512×982, a 32-pt housing 185 pt wide.
    private let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 982)

    private func macBook() -> NotchGeometry? {
        NotchGeometry.make(screenFrame: builtIn, topInset: 32, leftWidth: 663.5, rightWidth: 663.5)
    }

    func testNotchedScreenIsDetected() throws {
        let geo = try XCTUnwrap(macBook())
        XCTAssertEqual(geo.notchSize, CGSize(width: 185, height: 32))
        XCTAssertEqual(geo.midX, 756)
    }

    /// An external display, or a notched one letterboxed below the housing: no top inset.
    func testNoTopInsetMeansNoNotch() {
        XCTAssertNil(NotchGeometry.make(screenFrame: builtIn, topInset: 0, leftWidth: 663.5, rightWidth: 663.5))
    }

    func testMenuBarStripsCoveringTheWholeWidthMeanNoNotch() {
        XCTAssertNil(NotchGeometry.make(screenFrame: builtIn, topInset: 32, leftWidth: 756, rightWidth: 756))
    }

    /// The built-in screen sits to the right of an external one, so its frame does not start at 0.
    func testFramesHangFromTheTopOfAnOffsetScreen() throws {
        let screen = NSRect(x: 2560, y: -200, width: 1512, height: 982)
        let geo = try XCTUnwrap(NotchGeometry.make(screenFrame: screen, topInset: 32,
                                                   leftWidth: 663.5, rightWidth: 663.5))
        let frame = geo.frame(for: CGSize(width: 400, height: 90))
        XCTAssertEqual(frame.maxY, screen.maxY)
        XCTAssertEqual(frame.midX, geo.midX, accuracy: 0.5)
        XCTAssertEqual(geo.notchRect.minX, 2560 + 663.5, accuracy: 0.5)
    }

    /// Every state shares the housing's centre, so resizing the window between states never moves
    /// what is drawn inside it.
    func testEveryStateIsCentredOnTheHousing() throws {
        let geo = try XCTUnwrap(macBook())
        let toast = NotchToast(title: "Copied", text: "hello")
        for mode: NotchModel.Mode in [.idle, .toast(toast), .shelf, .drop] {
            let size = NotchLayout.size(of: mode, notch: geo.notchSize)
            XCTAssertEqual(geo.frame(for: size).midX, geo.midX, accuracy: 0.5, "\(mode)")
            XCTAssertEqual(geo.frame(for: size).maxY, builtIn.maxY, "\(mode)")
        }
    }

    /// Idle stays inside the housing, so nothing of it shows against the menu bar.
    func testIdleShapeHidesBehindTheHousing() throws {
        let geo = try XCTUnwrap(macBook())
        let idle = NotchLayout.size(of: .idle, notch: geo.notchSize)
        XCTAssertLessThan(idle.width, geo.notchSize.width)
        XCTAssertLessThanOrEqual(idle.height, geo.notchSize.height)
        XCTAssertGreaterThan(idle.width, 0)
    }

    func testShelfFitsItsCards() throws {
        let geo = try XCTUnwrap(macBook())
        let shelf = NotchLayout.size(of: .shelf, notch: geo.notchSize)
        let n = CGFloat(NotchLayout.shelfCount)
        let cards = n * NotchLayout.shelfCardSize.width + (n - 1) * NotchLayout.shelfCardSpacing
        XCTAssertGreaterThanOrEqual(shelf.width, cards + 2 * NotchLayout.flare)
        XCTAssertGreaterThan(shelf.height, geo.notchSize.height + NotchLayout.shelfCardSize.height)
    }

    func testSummaries() {
        XCTAssertEqual(NotchText.firstLine(of: "\n\n   hello world  \nsecond"), "hello world")
        let link = ClipboardItem(type: .url, text: "https://www.example.com/a/b")
        XCTAssertEqual(NotchText.summary(of: link), "example.com/a/b")
        let files = ClipboardItem(type: .file, fileURLs: [URL(fileURLWithPath: "/tmp/a.txt"),
                                                         URL(fileURLWithPath: "/tmp/b.txt")])
        XCTAssertEqual(NotchText.summary(of: files), "a.txt +1")
        var named = ClipboardItem(type: .text, text: "xyz")
        named.label = "My snippet"
        XCTAssertEqual(NotchText.summary(of: named), "My snippet")
    }
}

final class NotchShelfLayoutTests: XCTestCase {
    private let notch = CGSize(width: 185, height: 32)

    /// Two items get a band sized for the header, not one built for six cards.
    func testShelfNarrowsWithFewItems() {
        let few = NotchLayout.size(of: .shelf, notch: notch, shelfItems: 2)
        let full = NotchLayout.size(of: .shelf, notch: notch, shelfItems: 6)
        XCTAssertLessThan(few.width, full.width)
        XCTAssertGreaterThanOrEqual(few.width, notch.width + 2 * NotchLayout.shelfWing)
        XCTAssertEqual(few.height, full.height)
    }

    func testAge() {
        let now = Date()
        XCTAssertEqual(NotchText.age(of: now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(NotchText.age(of: now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(NotchText.age(of: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(NotchText.age(of: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }
}

final class NotchTextStyleTests: XCTestCase {
    func testShortTextIsSetLarge() {
        XCTAssertEqual(NotchText.textStyle(of: "Ok, hẹn 7h tối nhé 👍"), .short)
    }

    func testCodeIsMonospaced() {
        let swift = "func greet(_ name: String) -> String {\n    return \"Hello\"\n}"
        XCTAssertEqual(NotchText.textStyle(of: swift), .code)
        XCTAssertEqual(NotchText.textStyle(of: "const a = 1;\nconst b = 2;"), .code)
    }

    func testProseIsNotCode() {
        let prose = "Đây là một đoạn văn bản dài bằng tiếng Việt để xem card hiển thị nhiều dòng ra sao."
        XCTAssertEqual(NotchText.textStyle(of: prose), .prose)
        XCTAssertEqual(NotchText.textStyle(of: "Mua sữa\nMua trứng\nGhé tiệm giặt"), .prose)
    }
}

final class NotchShelfItemsTests: XCTestCase {
    /// The history comes back from disk pinned first; the shelf is about what was just copied.
    func testNewestFirstWhateverIsPinned() {
        let now = Date()
        var oldPinned = ClipboardItem(type: .text, text: "old pinned", timestamp: now.addingTimeInterval(-86_400))
        oldPinned.isPinned = true
        let fresh = ClipboardItem(type: .text, text: "fresh", timestamp: now)
        let older = ClipboardItem(type: .text, text: "older", timestamp: now.addingTimeInterval(-60))
        let recent = NotchShelfItems.recent([oldPinned, older, fresh], count: 2)
        XCTAssertEqual(recent.map(\.text), ["fresh", "older"])
    }
}
