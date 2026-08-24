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

    /// What a plain, unformatted run looks like in the editor.
    ///
    /// One definition because three things have to agree on it: the seed for an item with no
    /// formatting, what "clear formatting" returns a selection to, and the comparison
    /// `carriesFormatting` makes when deciding whether an edit is worth storing as RTF. They drifted
    /// apart the moment there were two copies of the literal.
    static let plainFont = NSFont.systemFont(ofSize: 13)
    static var plainDefaults: [NSAttributedString.Key: Any] {
        [.font: plainFont, .foregroundColor: NSColor.labelColor]
    }

    /// Whether the editor offers formatting for this item.
    ///
    /// Every Text item, now that there is a toolbar — a plain snippet can be given a bold word or a
    /// link. A Link is still excluded: it is edited as the address it is, not as the styled anchor
    /// a browser happened to put on the pasteboard.
    ///
    /// This used to also require that the item *arrived* formatted. That was guarding against a
    /// real hazard — an `NSTextView` applies a default font to everything it is given, so asking
    /// "does the result carry attributes?" answers yes for every plain snippet ever opened, and
    /// they would all silently start storing RTF. The guard has not been dropped, it has moved to
    /// `carriesFormatting`, which asks the sharper question: does the saved text differ from the
    /// defaults it opened with?
    static func keepsFormatting(_ item: ClipboardItem) -> Bool {
        item.type == .text
    }

    /// Whether an edited string carries anything `plainDefaults` does not.
    ///
    /// A missing `.font` or `.foregroundColor` counts as plain, because that is what unstyled text
    /// comes back as from the HTML importer. Fonts are compared by name and size rather than by
    /// `==`: the same face arrives as a different instance depending on which importer produced it.
    static func carriesFormatting(_ attributed: NSAttributedString) -> Bool {
        var formatted = false
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length),
                                       options: []) { attrs, _, stop in
            let font = attrs[.font] as? NSFont
            let plainFace = font == nil
                || (font?.fontName == plainFont.fontName && font?.pointSize == plainFont.pointSize)
            let plainColour = (attrs[.foregroundColor] as? NSColor).map { $0 == .labelColor } ?? true
            let unadorned = attrs[.link] == nil
                && attrs[.backgroundColor] == nil
                && (attrs[.underlineStyle] as? Int ?? 0) == 0
                && (attrs[.strikethroughStyle] as? Int ?? 0) == 0
            if !(plainFace && plainColour && unadorned) {
                formatted = true
                stop.pointee = true
            }
        }
        return formatted
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
        if item.type == .text,
           let formatted = parsed ?? RichTextRenderer.cachedParse(item)?.text {
            return (formatted, true)
        }
        // A Text item with nothing to parse still opens on an editor that allows formatting — it
        // just starts out plain. A Link opens plain and stays plain.
        return (NSAttributedString(string: item.text ?? "", attributes: plainDefaults),
                item.type == .text)
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
