import AppKit
import SwiftUI

/// A handle on the live editor.
///
/// Holds the text view weakly and reads it on demand, rather than copying the document out on every
/// keystroke — a large snippet would otherwise be duplicated per character typed.
final class EditBuffer {
    weak var textView: NSTextView?

    var plain: String { textView?.string ?? "" }

    /// `NSTextView.attributedString()` hands back the live `NSTextStorage`, not a snapshot — it is
    /// the same mutable object the view keeps editing. Anything that holds on to a read (raw mode's
    /// `formattedBeforeRaw`, in particular) would silently change out from under it the next time the
    /// user typed, so this makes an honest immutable copy instead. (Measured: capturing
    /// `textView.attributedString()` directly, then setting `textView.string` to something else,
    /// changed the "captured" value too — same object, not a copy.)
    var attributed: NSAttributedString {
        NSAttributedString(attributedString: textView?.attributedString() ?? NSAttributedString())
    }
}

/// What the editor is showing, and what Save should take from it.
///
/// The seed travels through here rather than being recomputed in `body`, because switching mode is
/// a *rebuild* of the text view, not an update of it. `EditableRichText` seeds once in `makeNSView`
/// and deliberately does nothing in `updateNSView` — pushing a seed back in on a SwiftUI update
/// throws away what the user has typed and moves the caret back to the start. Bumping `generation` and
/// letting SwiftUI build a fresh view honours that rule instead of breaking it.
@MainActor
final class EditSession: ObservableObject {

    enum Mode { case formatted, raw }

    @Published private(set) var mode: Mode = .formatted
    @Published private(set) var seed = NSAttributedString()
    /// Changes on every rebuild; the editor is `.id()`-ed on it.
    @Published private(set) var generation = 0
    @Published var error: String?
    @Published var state = RichTextState()

    let buffer = EditBuffer()

    /// The formatted text as it stood when raw mode was entered, and the markup handed over then.
    /// Both nil outside raw mode.
    private var formattedBeforeRaw: NSAttributedString?
    private var markupHandedOver: String?

    /// Starts a fresh edit.
    func begin(with text: NSAttributedString) {
        mode = .formatted
        seed = text
        error = nil
        state = RichTextState()
        formattedBeforeRaw = nil
        markupHandedOver = nil
        generation += 1
    }

    func toggleMode() {
        switchTo(mode == .formatted ? .raw : .formatted)
    }

    func switchTo(_ target: Mode) {
        guard target != mode else { return }
        error = nil
        switch target {
        case .raw:
            let formatted = buffer.attributed
            guard let markup = RichTextHTML.html(from: formatted) else {
                error = "This item is too large to show as HTML."
                return
            }
            formattedBeforeRaw = formatted
            markupHandedOver = markup
            seed = EditSession.rawSeed(markup)
        case .formatted:
            guard let parsed = parsedFromRaw() else {
                error = "That HTML could not be read."
                return
            }
            seed = parsed
            formattedBeforeRaw = nil
            markupHandedOver = nil
        }
        mode = target
        generation += 1
    }

    /// What Save should store: the formatted text, parsing the raw source first when that is what
    /// is on screen. Nil only when the markup cannot be read at all.
    func resolvedDraft() -> NSAttributedString? {
        switch mode {
        case .formatted: return buffer.attributed
        case .raw:       return parsedFromRaw()
        }
    }

    /// Untouched markup hands back the object it came from rather than a re-parse. Every conversion
    /// costs a little fidelity and nobody should pay it for a mis-click.
    private func parsedFromRaw() -> NSAttributedString? {
        let typed = buffer.plain
        if typed == markupHandedOver, let original = formattedBeforeRaw { return original }
        return RichTextHTML.attributed(from: typed)
    }

    /// Replaces the whole document, through the text view's own change machinery so the rewrite
    /// lands on its undo stack — a conversion the user did not mean must be one ⌘Z away.
    func replaceAll(with string: String) {
        guard let view = buffer.textView else { return }
        let whole = NSRange(location: 0, length: (view.string as NSString).length)
        guard view.shouldChangeText(in: whole, replacementString: string) else { return }
        view.replaceCharacters(in: whole, with: string)
        view.didChangeText()
    }

    // MARK: - Commands

    func run(_ command: RichTextCommand) {
        guard let view = buffer.textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        // Through the text view's own change machinery so the edit lands on its undo stack, rather
        // than mutating the storage behind its back.
        if range.length > 0 { _ = view.shouldChangeText(in: range, replacementString: nil) }
        view.typingAttributes = command.apply(to: storage, range: range,
                                              typing: view.typingAttributes)
        if range.length > 0 { view.didChangeText() }
        refreshState()
    }

    func refreshState() {
        guard mode == .formatted,
              let view = buffer.textView,
              let storage = view.textStorage
        else { return }
        state = RichTextState.read(from: storage,
                                   range: view.selectedRange(),
                                   typing: view.typingAttributes)
    }

    /// `refreshState()`, unless `generation` names an edit the session has already moved past.
    ///
    /// A mode switch bumps `generation` and rebuilds the text view (see the type comment), but the
    /// outgoing view's delegate can still fire once more on the way out — synchronously as AppKit
    /// resigns it as first responder, or later through a coalesced notification — after the session
    /// has already moved to the next generation. `ItemPreviewWindow` captures the generation a view
    /// was built for and passes it back in here, so a view being torn down can never overwrite the
    /// state of the one that replaced it.
    func refreshState(ifCurrent generation: Int) {
        guard generation == self.generation else { return }
        refreshState()
    }

    /// Wires `view` up as the live editor and reports its state immediately.
    ///
    /// Two things a fresh rebuild would otherwise get wrong: nothing else calls `refreshState()`
    /// when the editor is first built, so `state` would sit at its `RichTextState()` default until
    /// the user made a selection; and `typingAttributes` on a brand-new `NSTextView` has not been
    /// populated by AppKit — `view` was seeded by handing its storage a finished string directly
    /// (see `EditableRichText.makeNSView`), which bypasses the typing machinery that would normally
    /// keep `typingAttributes` in step with the caret. Left alone, even an immediate refresh would
    /// read an empty `typing` and report the system face with no size — `RichTextState`'s armed
    /// branch trusts `typing` completely once the range is empty. Priming it from the run the caret
    /// actually sits in is what makes that refresh honest.
    func attach(_ view: NSTextView) {
        buffer.textView = view
        if let storage = view.textStorage, storage.length > 0, view.selectedRange().length == 0 {
            let index = min(max(view.selectedRange().location, 0), storage.length - 1)
            view.typingAttributes = storage.attributes(at: index, effectiveRange: nil)
        }
        refreshState()
    }

    /// Monospaced, because what raw mode shows is source and its nesting carries meaning a
    /// proportional font throws away — the same reason the file pane uses one.
    private static func rawSeed(_ markup: String) -> NSAttributedString {
        NSAttributedString(string: markup, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}
