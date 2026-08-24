import XCTest
@testable import xPaste

/// The encoding a saved page is read back in.
///
/// A page's charset usually arrives in the HTTP `Content-Type` header, and that header does not
/// survive the trip to disk. Opened from a file, an undeclared document falls back to windows-1252
/// and every accented character in it turns to mojibake — `Cửa hàng` reads as `Cá»­a hÃ ng`. These
/// check the declaration is put back, and — just as important — that a document which already says
/// what it is comes through untouched.
final class HTMLCharsetTests: XCTestCase {

    private func string(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: - Putting the declaration back

    func testDeclaresTheServedCharsetWhenTheMarkupDoesNot() {
        let html = Data("<!doctype html><html lang=\"vi\"><head><title>Cửa hàng</title></head></html>".utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8")
        XCTAssertEqual(string(out),
                       "<!doctype html><html lang=\"vi\"><head><meta charset=\"utf-8\"><title>Cửa hàng</title></head></html>")
    }

    func testKeepsTheBodyBytesExactlyAsServed() {
        let html = Data("<html><head></head><body>Cửa hàng</body></html>".utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8")
        // Nothing but the tag is added: the page is still the page it was served as.
        XCTAssertEqual(out.count, html.count + Data("<meta charset=\"utf-8\">".utf8).count)
        XCTAssertTrue(string(out).hasSuffix("<body>Cửa hàng</body></html>"))
    }

    func testTheDeclarationLandsWhereABrowserWillSeeIt() {
        // Browsers only pre-scan the opening kilobyte for an encoding, so a declaration further in
        // than that is a declaration nobody reads.
        let head = "<!doctype html><html><head>"
        let html = Data((head + String(repeating: "<link rel=\"preconnect\" href=\"//a.example\">", count: 200) + "</head>").utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8")
        let offset = string(out).range(of: "<meta charset=").map { string(out).distance(from: string(out).startIndex, to: $0.lowerBound) }
        XCTAssertNotNil(offset)
        XCTAssertLessThan(offset ?? .max, 1024)
    }

    func testFallsBackToTheHTMLTagWhenThereIsNoHead() {
        let html = Data("<html><body>Cửa hàng</body></html>".utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8")
        XCTAssertEqual(string(out), "<html><meta charset=\"utf-8\"><body>Cửa hàng</body></html>")
    }

    func testMatchesTheOpeningTagWhateverItsCase() {
        let html = Data("<!DOCTYPE HTML><HTML><HEAD><TITLE>Cửa hàng</TITLE></HEAD></HTML>".utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8")
        XCTAssertEqual(string(out),
                       "<!DOCTYPE HTML><HTML><HEAD><meta charset=\"utf-8\"><TITLE>Cửa hàng</TITLE></HEAD></HTML>")
    }

    func testHandlesAHeadTagCarryingAttributes() {
        let html = Data("<html><head profile=\"http://example.com/p\"><title>x</title></head></html>".utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8")
        XCTAssertTrue(string(out).contains("<head profile=\"http://example.com/p\"><meta charset=\"utf-8\"><title>"))
    }

    // MARK: - Leaving a document that already says what it is alone

    func testLeavesAPageThatAlreadyDeclaresItsCharsetAlone() {
        let html = Data("<html><head><meta charset=\"utf-8\"><title>x</title></head></html>".utf8)
        XCTAssertEqual(HTMLCharset.declaring(html, charset: "utf-8"), html)
    }

    func testLeavesTheOlderHTTPEquivFormAlone() {
        let html = Data("""
            <html><head><meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1"></head></html>
            """.utf8)
        XCTAssertEqual(HTMLCharset.declaring(html, charset: "utf-8"), html)
    }

    func testAByteOrderMarkCountsAsADeclaration() {
        // A BOM outranks everything else a browser could read, so a document carrying one needs no
        // help and must not be rewritten.
        var html = Data([0xEF, 0xBB, 0xBF])
        html.append(Data("<html><head></head></html>".utf8))
        XCTAssertEqual(HTMLCharset.declaring(html, charset: "utf-8"), html)
    }

    func testTheWordCharsetInsideAScriptIsNotADeclaration() {
        // Straight from the Chrome Web Store page that started this: its loader sets
        // `c.charset="UTF-8"` on a script element, which is not a declaration about the document.
        let html = Data("""
            <!doctype html><html lang="vi"><head><script>function f(c){c.charset="UTF-8";}</script></head></html>
            """.utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8")
        XCTAssertTrue(string(out).contains("<head><meta charset=\"utf-8\"><script>"))
    }

    // MARK: - When there is nothing safe to say

    func testLeavesAFragmentWithNoOpeningTagAlone() {
        let html = Data("<p>Cửa hàng</p>".utf8)
        XCTAssertEqual(HTMLCharset.declaring(html, charset: "utf-8"), html)
    }

    func testDeclaresWhatWasServedEvenWhenItIsNotUTF8() {
        // Latin-1 bytes: 0xE9 is é in windows-1252 and not valid UTF-8 at all. The header is the
        // only thing that knows, so it is the thing repeated — the bytes stay as they came.
        var html = Data("<html><head></head><body>caf".utf8)
        html.append(0xE9)
        html.append(Data("</body></html>".utf8))
        let out = HTMLCharset.declaring(html, charset: "windows-1252")
        XCTAssertEqual(out.count, html.count + Data("<meta charset=\"windows-1252\">".utf8).count)
        XCTAssertTrue(out.contains(0xE9))
    }

    func testSaysNothingWhenNobodyKnowsTheEncoding() {
        // No header, and bytes that are not valid UTF-8: any guess here would be a guess written
        // into the user's file. Better to leave the browser its own fallback.
        var html = Data("<html><head></head><body>caf".utf8)
        html.append(0xE9)
        html.append(Data("</body></html>".utf8))
        XCTAssertEqual(HTMLCharset.declaring(html, charset: nil), html)
    }

    func testAssumesUTF8WhenThereIsNoHeaderButTheBytesDecode() {
        let html = Data("<html><head></head><body>Cửa hàng</body></html>".utf8)
        let out = HTMLCharset.declaring(html, charset: nil)
        XCTAssertTrue(string(out).contains("<meta charset=\"utf-8\">"))
    }

    func testSaysNothingAboutAnASCIIOnlyPage() {
        // Every candidate encoding agrees about ASCII, so there is nothing to fix and no reason to
        // touch the file.
        let html = Data("<html><head></head><body>plain</body></html>".utf8)
        XCTAssertEqual(HTMLCharset.declaring(html, charset: nil), html)
    }

    func testRefusesACharsetNameItCannotWriteSafely() {
        // A header is remote input. A name with a quote in it would break out of the attribute and
        // rewrite the document, so anything that is not a plain token is dropped.
        let html = Data("<html><head></head><body>Cửa hàng</body></html>".utf8)
        let out = HTMLCharset.declaring(html, charset: "utf-8\"><script>alert(1)</script>")
        XCTAssertFalse(string(out).contains("<script>"))
        // The bytes decode, so it still gets the honest answer rather than nothing.
        XCTAssertTrue(string(out).contains("<meta charset=\"utf-8\">"))
    }

    func testLeavesSomethingThatIsNotMarkupAlone() {
        let json = Data("{\"name\": \"Cửa hàng\"}".utf8)
        XCTAssertEqual(HTMLCharset.declaring(json, charset: "utf-8"), json)
    }
}
