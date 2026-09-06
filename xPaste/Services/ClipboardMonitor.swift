import AppKit

final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private var timer: Timer?
    private var lastChangeCount: Int

    /// The board this monitor watches. Injectable so the "this change is ours" handshake can be
    /// exercised on a scratch pasteboard rather than on the user's real clipboard.
    private let pasteboard: NSPasteboard

    /// Where a captured image is decoded and compressed.
    ///
    /// Serial, so two copies made in quick succession reach the history in the order they were
    /// made — a pool let a small second image overtake a large first one. And one queue rather than
    /// a detached task per copy because `NSImage` is not `Sendable`: it is built and used entirely
    /// here, and only `Data` ever crosses a boundary.
    private let captureQueue = DispatchQueue(label: "com.user.xPaste.capture", qos: .userInitiated)

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    static let defaultInterval: TimeInterval = 0.1
    private var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "clipboardScanInterval")
        return v > 0 ? v : Self.defaultInterval
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        stop()
        start()
    }

    func markNextChangeAsOwn() {
        lastChangeCount = pasteboard.changeCount
    }

    /// Whether what is on the pasteboard right now has been claimed as xPaste's own — i.e. the
    /// next poll passes over it instead of capturing it as a new item.
    var ownsCurrentChange: Bool { pasteboard.changeCount == lastChangeCount }

    /// Writes to the pasteboard and claims the change, in that order.
    ///
    /// The order is the whole point. `markNextChangeAsOwn` records the count *as it stands*, so
    /// claiming before writing claims the change that came before xPaste's own — and the write
    /// that follows is then captured right back into the history, filed under whichever app
    /// happened to be frontmost, replacing the item it was pasted from.
    func writeOwned(_ write: (NSPasteboard) -> Void) {
        write(pasteboard)
        markNextChangeAsOwn()
    }

    /// The path a captured item's text reduces to, or nil when there is nothing to strip.
    ///
    /// Deciding is kept apart from doing so the never-store filter can run in between. A pattern is
    /// a "hands off this content" instruction, and rewriting the clipboard of something the user
    /// forbade storing would still be touching it — so nothing may be written until the filter has
    /// had its say. This function has no side effects at all.
    static func remotePathRewrite(for item: ClipboardItem) -> String? {
        guard item.type == .text, let text = item.text else { return nil }
        return RemotePath.strip(text)
    }

    /// Puts `stripped` on the pasteboard, and returns the item to store in place of `item`.
    ///
    /// Lives here rather than in `ClipboardItem.from` because the rewrite has to reach the system
    /// pasteboard too, and this is the only type that owns the handshake that keeps xPaste's own
    /// writes out of the history.
    ///
    /// Internal rather than private so it can be exercised against a scratch pasteboard; `poll` is
    /// the only caller in the app.
    func applyingRemotePath(_ stripped: String, to item: ClipboardItem) -> ClipboardItem {
        // The pasteboard write, but only while the board still holds what was captured. `poll`
        // reads the change count and then spends real time in `ClipboardItem.from` and
        // `PasteboardPayload.capture`; a copy another app makes inside that window would be
        // destroyed by `clearContents` and, because the write is claimed, never captured on the
        // next tick either. Reading is harmless to race with; this is the one place `poll` became
        // destructive, and this is the whole of the destruction.
        //
        // The replacement item is returned either way. Skipping the write is about not clobbering
        // someone else's copy; the history's own rule — that what it stores is the stripped form —
        // has nothing to do with that race, and dropping the item or storing the un-stripped form
        // would both break it for no gain.
        if ownsCurrentChange {
            // `clearContents` rather than overwriting the string: the source app offered other
            // representations of the same URL, and a plain string laid on top of them would leave
            // the receiving app free to prefer one of the originals.
            writeOwned { board in
                board.clearContents()
                board.setString(stripped, forType: .string)
            }
        }

        // A fresh item rather than a mutated one, for the payload's sake. Pasting from the panel
        // reads the payload, not `text`; keeping the captured one would leave a card that reads
        // `/home/www` and pastes `sftp://10.0.0.5/home/www`.
        var replacement = ClipboardItem(type: .text, text: stripped)
        replacement.payload = PasteboardPayload.plainText(stripped)
        return replacement
    }

    /// The strings a never-store pattern is matched against.
    ///
    /// What was copied and what the rewrite would replace it with, because either can be the one
    /// the user wrote their pattern against. `10.0.0.5` is a natural way to say "never keep my
    /// server paths", and it appears only in what was copied; percent-decoding runs the other way,
    /// putting `/home/bí mật` only in the rewrite and never in the `%62%C3%AD…` that was copied.
    static func exclusionCandidates(for item: ClipboardItem, rewrittenTo rewrite: String?) -> [String] {
        var candidates = [item.text, item.fileURLs?.map(\.path).joined(separator: "\n")]
            .compactMap { $0 }
        if let rewrite, rewrite != item.text { candidates.append(rewrite) }
        return candidates
    }

    // De-facto standard pasteboard hints (nspasteboard.com) set by password managers and
    // apps that generate throwaway content.
    private static let concealedType = "org.nspasteboard.ConcealedType"
    private static let transientTypes = ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]

    private func poll() {
        let pb = pasteboard
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Privacy filters.
        let defaults = UserDefaults.standard
        if let bid = sourceBundleID,
           let ignored = defaults.stringArray(forKey: "ignoredAppBundleIDs"),
           ignored.contains(bid) {
            return
        }
        let types = (pb.types ?? []).map(\.rawValue)
        if defaults.bool(forKey: "ignoreConfidentialContent"),
           types.contains(Self.concealedType) {
            return
        }
        if defaults.bool(forKey: "ignoreTransientContent"),
           types.contains(where: { Self.transientTypes.contains($0) }) {
            return
        }

        let hasFileURLs = (pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.isEmpty == false

        if !hasFileURLs,
           let types = pb.types,
           types.contains(where: { $0 == .tiff || $0 == .png }) {
            // Read on this thread, decode on the other: the bytes are `Sendable`, the `NSImage`
            // built from them is not.
            let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff)
            // Read here, not on the capture queue: the pasteboard is shared state that the next
            // copy replaces, and by the time a queued block runs it can be describing something
            // else entirely.
            let payload = PasteboardPayload.capture(from: pb)
            if let raw {
                captureQueue.async {
                    // Explicitly pooled. Compressing one 2200x1400 capture allocates the decoded
                    // bitmap several times over — a TIFF, a rep built from it, a scaled rep per
                    // step down, and a JPEG per quality tried — and most of that comes back
                    // autoreleased. A dispatch queue drains its own pool only when it goes idle,
                    // and a run of copies never lets it, so the peaks stacked instead of cancelling.
                    autoreleasepool {
                        // Straight to a bitmap: the pasteboard already handed over encoded bytes,
                        // and routing them through `NSImage` would decode the picture three times
                        // over — see `NSBitmapImageRep.compressedData`.
                        guard let bitmap = NSBitmapImageRep(data: raw),
                              let compressed = bitmap.compressedData(maxBytes: 1_000_000) else { return }
                        var item = ClipboardItem(type: .image, imageData: compressed)
                        item.sourceAppBundleID = sourceBundleID
                        // The compressed copy is the card's thumbnail; the payload keeps what the
                        // source actually put on the pasteboard. Storing both is what makes a paste
                        // give back the original picture rather than xPaste's re-encoding of it —
                        // which is all the history used to be able to return.
                        item.payload = payload
                        DispatchQueue.main.async { ClipboardStore.shared.add(item) }
                        // `compressed`, not `raw`, even though the original is right here: Vision
                        // resizes its input, so the smaller copy is both cheaper and no worse at
                        // small text. See `OCRService.tileSide` and the note in `startBackfill`.
                        OCRService.scan(itemID: item.id, imageData: compressed)
                    }
                }
                return
            }
        }

        guard var item = ClipboardItem.from(pasteboard: pb) else { return }

        // Decided here, applied below: everything between the two is the never-store filter, and a
        // pattern is a "hands off this content" instruction that the rewrite has to obey as much
        // as the write to disk does.
        let rewrite = Self.remotePathRewrite(for: item)

        // Never-store patterns (tokens, keys, card numbers). The point is that this content never
        // reaches disk at all — and, for anything caught here, never reaches the pasteboard either.
        let patterns = ExclusionRules.storedPatterns(defaults)
        if !patterns.isEmpty {
            if Self.exclusionCandidates(for: item, rewrittenTo: rewrite).contains(where: {
                ExclusionRules.shouldExclude($0, patterns: patterns)
            }) {
                return
            }
        }

        if let rewrite { item = applyingRemotePath(rewrite, to: item) }

        item.sourceAppBundleID = sourceBundleID
        DispatchQueue.main.async {
            ClipboardStore.shared.add(item)
        }
    }
}
