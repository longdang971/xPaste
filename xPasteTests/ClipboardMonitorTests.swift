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

    private var serverPath: String { "sftp://10.0.0.5/home/www" }

    /// Deciding must not touch anything: `poll` runs the never-store filter between the decision
    /// and the write, and that ordering is only safe because this half has no side effects.
    func testDecidingTheRewriteTouchesNothing() {
        let pb = scratchBoard("remote-path-decide")
        pb.clearContents()
        pb.setString(serverPath, forType: .string)
        let before = pb.changeCount

        XCTAssertEqual(ClipboardMonitor.remotePathRewrite(for: textItem(serverPath)), "/home/www")

        XCTAssertEqual(pb.changeCount, before)
        XCTAssertEqual(pb.string(forType: .string), serverPath)
    }

    func testTextThatIsNotAServerPathHasNoRewrite() {
        XCTAssertNil(ClipboardMonitor.remotePathRewrite(for: textItem("just some text")))
    }

    /// Only text items. A Link card, a colour, an image, a file or a folder is passed through — and
    /// a `.url` item in particular can only be `http`/`https`, which `RemotePath` refuses anyway.
    func testOnlyTextItemsAreConsidered() {
        var link = textItem(serverPath)
        link.type = .url
        XCTAssertNil(ClipboardMonitor.remotePathRewrite(for: link))
    }

    func testApplyingARewritePutsThePathOnThePasteboard() {
        let pb = scratchBoard("remote-path")
        let monitor = ClipboardMonitor(pasteboard: pb)

        let stored = monitor.applyingRemotePath("/home/www", to: textItem(serverPath))

        XCTAssertEqual(stored.text, "/home/www")
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
        pb.setString(serverPath, forType: .string)
        monitor.markNextChangeAsOwn()
        let before = pb.changeCount

        _ = monitor.applyingRemotePath("/home/www", to: textItem(serverPath))

        // Both halves. Ownership alone would hold just as well if the write had never happened —
        // the count would simply not have moved — so the write is asserted too.
        XCTAssertGreaterThan(pb.changeCount, before)
        XCTAssertEqual(pb.string(forType: .string), "/home/www")
        XCTAssertTrue(monitor.ownsCurrentChange)
    }

    /// Pasting from the panel reads the payload, not `text`. Keeping the captured one would leave a
    /// card that reads `/home/www` and pastes `sftp://10.0.0.5/home/www`.
    func testTheReplacementCarriesOnlyThePlainStrippedPath() {
        let pb = scratchBoard("remote-path-payload")
        let monitor = ClipboardMonitor(pasteboard: pb)

        let stored = monitor.applyingRemotePath("/home/www", to: textItem(serverPath))

        XCTAssertEqual(stored.payload, PasteboardPayload.plainText("/home/www"))
        XCTAssertNil(stored.payload?.items.first?.data(forType: "public.rtf"))
    }

    /// The same on the pasteboard side: `clearContents` drops the representations the source app
    /// offered, rather than leaving a plain string sitting on top of them.
    func testNoRepresentationOfTheOriginalSurvivesOnThePasteboard() {
        let pb = scratchBoard("remote-path-types")
        pb.clearContents()
        pb.setString(serverPath, forType: .string)
        pb.setData(Data("{\\rtf1 x}".utf8), forType: .rtf)
        let monitor = ClipboardMonitor(pasteboard: pb)

        _ = monitor.applyingRemotePath("/home/www", to: textItem(serverPath))

        XCTAssertNil(pb.data(forType: .rtf))
        XCTAssertEqual(pb.string(forType: .string), "/home/www")
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
        pb.setString(serverPath, forType: .string)
        monitor.markNextChangeAsOwn()

        // Someone else copies while the capture is still in flight.
        pb.clearContents()
        pb.setString("something else entirely", forType: .string)

        let stored = monitor.applyingRemotePath("/home/www", to: textItem(serverPath))

        XCTAssertEqual(pb.string(forType: .string), "something else entirely")
        // And left unclaimed, so the next poll still captures it.
        XCTAssertFalse(monitor.ownsCurrentChange)
        // The item is still stored stripped: the race is about not clobbering someone else's copy,
        // and has nothing to do with the history's rule about what it keeps.
        XCTAssertEqual(stored.text, "/home/www")
        XCTAssertEqual(stored.payload, PasteboardPayload.plainText("/home/www"))
    }
}

// MARK: - What a never-store pattern is matched against

extension ClipboardMonitorTests {

    /// A rule naming the server has to keep working after the host has been stripped out of the
    /// item, or the rewrite would quietly write to disk what an explicit rule forbade.
    func testAPatternNamingTheServerStillCatchesTheItem() {
        let captured = ClipboardItem(type: .text, text: "sftp://10.0.0.5/home/www")
        let candidates = ClipboardMonitor.exclusionCandidates(for: captured, rewrittenTo: "/home/www")

        XCTAssertTrue(candidates.contains(where: {
            ExclusionRules.shouldExclude($0, patterns: ["10.0.0.5"])
        }))
    }

    /// The other direction: percent-decoding puts text in the rewrite that was never in the copy,
    /// so a pattern written against the readable form has to be caught too.
    func testAPatternMatchingOnlyTheDecodedFormIsCaught() {
        let captured = ClipboardItem(type: .text, text: "sftp://h/home/b%C3%AD%20m%E1%BA%ADt")
        let candidates = ClipboardMonitor.exclusionCandidates(for: captured, rewrittenTo: "/home/bí mật")

        // Neither string alone would do: the pattern is absent from what was copied, and the
        // server is absent from the rewrite.
        XCTAssertFalse(ExclusionRules.shouldExclude(captured.text!, patterns: ["bí mật"]))
        XCTAssertTrue(candidates.contains(where: {
            ExclusionRules.shouldExclude($0, patterns: ["bí mật"])
        }))
    }

    /// An item with no rewrite lists its text once, not twice.
    func testAnItemThatWasNotRewrittenIsListedOnce() {
        let item = ClipboardItem(type: .text, text: "hello")
        XCTAssertEqual(ClipboardMonitor.exclusionCandidates(for: item, rewrittenTo: nil), ["hello"])
    }
}
