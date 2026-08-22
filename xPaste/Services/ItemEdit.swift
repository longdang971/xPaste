import AppKit

/// Turning what comes out of the editor back into something an item can store.
///
/// Separate from the popover so the encoding — the half that can silently lose a highlight — is
/// tested without a text view on screen.
enum ItemEdit {

    /// Whether this kind of item can be edited at all.
    ///
    /// A picture would need a picture editor, and a File item's "content" is a path rather than
    /// something to type into. The card's menu and the popover's pencil both ask here, so one
    /// cannot offer what the other refuses.
    static func canEdit(_ type: ClipboardContentType) -> Bool {
        switch type {
        case .text, .url:          return true
        case .image, .file, .folder: return false
        }
    }

    /// Whether the editor should keep formatting for this item.
    ///
    /// Only a Text item that arrived with formatting. Two exclusions, each deliberate: a Link is
    /// edited as the address it is, not as the styled anchor a browser happened to put on the
    /// pasteboard; and an item that never had formatting stays plain, because an `NSTextView`
    /// applies a default font to everything it is given — asking "does the result carry
    /// attributes?" would answer yes for every plain snippet ever opened, and they would all
    /// silently start storing RTF.
    static func keepsFormatting(_ item: ClipboardItem) -> Bool {
        item.type == .text && item.richData != nil
    }

    /// What the editor opens with, and whether that text is the formatted one.
    ///
    /// The two travel together on purpose. Deciding "keep formatting" from the item alone was
    /// wrong: the popover parses in its `.task`, while "Edit…" puts the editor on screen from
    /// `onAppear` — one runloop turn earlier. The editor was seeded with the plain string, and
    /// saving then re-encoded *that* as RTF, quietly flattening the highlight it was opened to
    /// preserve. Whether formatting is kept is now whether formatted text was actually in hand.
    ///
    /// `parsed` is the popover's own parse when it has landed; otherwise the shared cache is asked
    /// directly, which answers synchronously.
    static func editorSeed(for item: ClipboardItem,
                           parsed: NSAttributedString?) -> (text: NSAttributedString, formatted: Bool) {
        if keepsFormatting(item),
           let formatted = parsed ?? RichTextRenderer.cachedParse(item)?.text {
            return (formatted, true)
        }
        return (NSAttributedString(string: item.text ?? "",
                                   attributes: [.font: NSFont.systemFont(ofSize: 13),
                                                .foregroundColor: NSColor.labelColor]),
                false)
    }

    /// The RTF bytes for an edited attributed string, or nil when there is nothing to encode.
    ///
    /// Always RTF, even for an item that arrived as HTML: `ClipboardItem.captureRich` already
    /// prefers RTF when reading the pasteboard, so it is the representation the rest of the app
    /// treats as primary, and an editor round-trip is the natural moment to settle on it.
    static func rtf(from attributed: NSAttributedString) -> Data? {
        guard attributed.length > 0 else { return nil }
        return attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                              documentAttributes: [:])
    }

    /// The pasteboard type `rtf(from:)`'s bytes should be stored under.
    static let richType = NSPasteboard.PasteboardType.rtf.rawValue
}
