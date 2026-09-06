import XCTest
import AppKit
@testable import xPaste

/// The handshake that keeps xPaste's own writes out of the history.
///
/// Every paste path puts something on the pasteboard and then has to tell the monitor that the
/// change is xPaste's own, or the poll captures it right back as a new item — under the app that
/// was frontmost at that moment, and without the name or the pin the original carried.
final class ClipboardMonitorTests: XCTestCase {

    /// A pasteboard of its own, so the tests never touch what the user has copied.
    private func scratchBoard(_ name: String) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("xPasteTests.monitor.\(name)"))
        pb.clearContents()
        return pb
    }

    func testWritingThroughTheMonitorClaimsTheChange() {
        let pb = scratchBoard("owned")
        let monitor = ClipboardMonitor(pasteboard: pb)

        monitor.writeOwned { board in
            board.clearContents()
            board.setString("dragged text", forType: .string)
        }

        XCTAssertTrue(monitor.ownsCurrentChange)
        XCTAssertEqual(pb.string(forType: .string), "dragged text")
    }

    /// Why `writeOwned` exists at all: claiming first claims the change *before* xPaste's own, and
    /// the write that follows is left looking like a copy someone else made.
    func testClaimingBeforeTheWriteLeavesTheWriteUnclaimed() {
        let pb = scratchBoard("unclaimed")
        let monitor = ClipboardMonitor(pasteboard: pb)

        monitor.markNextChangeAsOwn()
        pb.clearContents()
        pb.setString("dragged text", forType: .string)

        XCTAssertFalse(monitor.ownsCurrentChange)
    }

    /// A change made by anything other than xPaste is not claimed, which is what makes the poll
    /// pick real copies up.
    func testAChangeNobodyClaimedIsNotOwned() {
        let pb = scratchBoard("foreign")
        let monitor = ClipboardMonitor(pasteboard: pb)

        pb.clearContents()
        pb.setString("copied elsewhere", forType: .string)

        XCTAssertFalse(monitor.ownsCurrentChange)
    }
}

// MARK: - Stripping a copied server path

/// `sftp://10.0.0.5/home/www` copied out of an SFTP client reaches the clipboard, and the history,
/// as `/home/www`. See `docs/superpowers/specs/2026-09-06-remote-path-strip-design.md`.
extension ClipboardMonitorTests {

    private func textItem(_ text: String) -> ClipboardItem {
        var item = ClipboardItem(type: .text, text: text)
        // What capture would have attached: the source app's own representations, which is exactly
        // what must not survive the rewrite.
        item.payload = PasteboardPayload(items: [
            .init(types: ["public.utf8-plain-text", "public.rtf"],
                  dataByType: ["public.utf8-plain-text": Data(text.utf8),
                               "public.rtf": Data("{\\rtf1 \(text)}".utf8)])
        ])
        return item
    }

    func testAServerPathIsRewrittenOnThePasteboard() {
        let pb = scratchBoard("remote-path")
        let monitor = ClipboardMonitor(pasteboard: pb)

        let stripped = monitor.strippingRemotePath(textItem("sftp://10.0.0.5/home/www"))

        XCTAssertEqual(stripped?.text, "/home/www")
        XCTAssertEqual(pb.string(forType: .string), "/home/www")
    }

    /// The write has to go through `writeOwned`, or the next poll captures it right back and the
    /// history grows a duplicate for every path copied.
    func testTheRewriteIsClaimedSoItIsNotCapturedAgain() {
        let pb = scratchBoard("remote-path-owned")
        let monitor = ClipboardMonitor(pasteboard: pb)
        // The copy the SFTP client made, and then `poll` noting the count it is working from —
        // which is the state the rewrite actually runs in.
        pb.clearContents()
        pb.setString("sftp://10.0.0.5/home/www", forType: .string)
        monitor.markNextChangeAsOwn()

        _ = monitor.strippingRemotePath(textItem("sftp://10.0.0.5/home/www"))

        XCTAssertTrue(monitor.ownsCurrentChange)
    }

    /// Pasting from the panel reads the payload, not `text`. Keeping the captured one would leave a
    /// card that reads `/home/www` and pastes `sftp://10.0.0.5/home/www`.
    func testTheReplacementCarriesOnlyThePlainStrippedPath() {
        let pb = scratchBoard("remote-path-payload")
        let monitor = ClipboardMonitor(pasteboard: pb)

        let stripped = monitor.strippingRemotePath(textItem("sftp://10.0.0.5/home/www"))

        XCTAssertEqual(stripped?.payload, PasteboardPayload.plainText("/home/www"))
        XCTAssertNil(stripped?.payload?.items.first?.data(forType: "public.rtf"))
    }

    /// The same on the pasteboard side: `clearContents` drops the representations the source app
    /// offered, rather than leaving a plain string sitting on top of them.
    func testNoRepresentationOfTheOriginalSurvivesOnThePasteboard() {
        let pb = scratchBoard("remote-path-types")
        pb.clearContents()
        pb.setString("sftp://10.0.0.5/home/www", forType: .string)
        pb.setData(Data("{\\rtf1 x}".utf8), forType: .rtf)
        let monitor = ClipboardMonitor(pasteboard: pb)

        _ = monitor.strippingRemotePath(textItem("sftp://10.0.0.5/home/www"))

        XCTAssertNil(pb.data(forType: .rtf))
        XCTAssertEqual(pb.string(forType: .string), "/home/www")
    }

    func testTextThatIsNotAServerPathIsLeftAlone() {
        let pb = scratchBoard("remote-path-none")
        pb.clearContents()
        pb.setString("just some text", forType: .string)
        let monitor = ClipboardMonitor(pasteboard: pb)

        let before = pb.changeCount
        XCTAssertNil(monitor.strippingRemotePath(textItem("just some text")))
        XCTAssertEqual(pb.changeCount, before)
        XCTAssertEqual(pb.string(forType: .string), "just some text")
    }

    /// Only text items. A Link card, a colour, an image, a file or a folder is passed through — and
    /// a `.url` item in particular can only be `http`/`https`, which `RemotePath` refuses anyway.
    func testOnlyTextItemsAreConsidered() {
        let pb = scratchBoard("remote-path-type")
        let monitor = ClipboardMonitor(pasteboard: pb)

        var link = textItem("sftp://10.0.0.5/home/www")
        link.type = .url

        let before = pb.changeCount
        XCTAssertNil(monitor.strippingRemotePath(link))
        XCTAssertEqual(pb.changeCount, before)
    }
}


// MARK: - Racing with another app's copy

extension ClipboardMonitorTests {

    /// `poll` reads the change count, then spends real time capturing the payload. A copy landing
    /// in that window must not be wiped by the rewrite — before this feature `poll` only read, and
    /// a racing copy was simply captured on the next tick.
    func testACopyLandingDuringCaptureIsNotDestroyed() {
        let pb = scratchBoard("remote-path-race")
        let monitor = ClipboardMonitor(pasteboard: pb)
        pb.clearContents()
        pb.setString("sftp://10.0.0.5/home/www", forType: .string)
        monitor.markNextChangeAsOwn()

        // Someone else copies while the capture is still in flight.
        pb.clearContents()
        pb.setString("something else entirely", forType: .string)

        XCTAssertNil(monitor.strippingRemotePath(textItem("sftp://10.0.0.5/home/www")))
        XCTAssertEqual(pb.string(forType: .string), "something else entirely")
        // And it is left unclaimed, so the next poll still captures it.
        XCTAssertFalse(monitor.ownsCurrentChange)
    }
}

// MARK: - What a never-store pattern is matched against

extension ClipboardMonitorTests {

    /// A rule naming the server has to keep working after the host has been stripped out of the
    /// item, or the rewrite would quietly write to disk what an explicit rule forbade.
    func testAPatternMatchingWhatWasCopiedStillApplies() {
        let stored = ClipboardItem(type: .text, text: "/home/www")
        let candidates = ClipboardMonitor.exclusionCandidates(
            for: stored, captured: "sftp://10.0.0.5/home/www")

        XCTAssertTrue(candidates.contains("sftp://10.0.0.5/home/www"))
        XCTAssertTrue(ExclusionRules.shouldExclude(
            candidates.first(where: { $0.contains("10.0.0.5") }) ?? "", patterns: ["10.0.0.5"]))
    }

    /// The other direction: percent-decoding puts text in the stored item that was never in the
    /// copy, so the stored text has to be matched too.
    func testThePatternIsAlsoMatchedAgainstTheStoredText() {
        let stored = ClipboardItem(type: .text, text: "/home/bí mật")
        let candidates = ClipboardMonitor.exclusionCandidates(
            for: stored, captured: "sftp://h/home/b%C3%AD%20m%E1%BA%ADt")

        XCTAssertTrue(candidates.contains("/home/bí mật"))
    }

    /// An untouched item lists its text once, not twice.
    func testAnItemThatWasNotRewrittenIsListedOnce() {
        let item = ClipboardItem(type: .text, text: "hello")
        XCTAssertEqual(ClipboardMonitor.exclusionCandidates(for: item, captured: "hello"), ["hello"])
    }
}
