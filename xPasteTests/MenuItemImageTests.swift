import XCTest
import AppKit
@testable import xPaste

/// macOS 27 stopped drawing menu item images on its own: `preferredImageVisibility` starts at
/// `.automatic`, and under that AppKit "will typically hide images" (NSMenuItem.h). Every item
/// that carries a symbol has to say `.visible` or the card's right-click menu comes up bare.
final class MenuItemImageTests: XCTestCase {
    func testItemWithSymbolCarriesTheImage() {
        let item = ClosureMenuItem(title: "Copy", symbol: "doc.on.doc") {}
        XCTAssertNotNil(item.image)
    }

    func testItemWithSymbolAsksForAVisibleImage() throws {
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("preferredImageVisibility only exists on macOS 27 and later")
        }
        let item = ClosureMenuItem(title: "Copy", symbol: "doc.on.doc") {}
        XCTAssertEqual(item.preferredImageVisibility, .visible)
    }

    func testItemWithoutASymbolIsLeftAlone() throws {
        guard #available(macOS 27.0, *) else {
            throw XCTSkip("preferredImageVisibility only exists on macOS 27 and later")
        }
        let item = ClosureMenuItem(title: "Paste") {}
        XCTAssertNil(item.image)
        XCTAssertEqual(item.preferredImageVisibility, .automatic)
    }
}
