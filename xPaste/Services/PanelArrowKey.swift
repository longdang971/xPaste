import AppKit

/// Whether a key press is an arrow that should walk the row of cards, and which way.
///
/// Decided here, in `AppDelegate`'s key monitor, for the same two reasons `PreviewSpaceKey` is —
/// and it took the same bug to learn them twice.
///
/// The arrows used to be four hidden `.keyboardShortcut` Buttons in the panel, guarded by
/// `.disabled(searchFocused || isRenaming)`. That guard reads a `@FocusState`, which says where
/// AppKit's first responder is — not whether the search box is on screen, and not whether there is
/// anything in it. Two things followed from that, both measured with the first responder logged on
/// every press:
///
///   * The search box keeps first responder after the filter sheet closes over it (AppKit hands
///     the panel's responder back when the popover's window gives up key). With nothing typed
///     into it, every ←/→ after that moved a caret through an empty string while the user was
///     looking at cards, and the row stopped answering the arrows entirely.
///   * `showSearch` and `searchFocused` could come apart: the magnifier takes focus a runloop
///     turn after it opens the box, and if the box folds away inside that gap — Escape closes the
///     panel, and `.panelWillHide` closes the search with it — focus lands on a field that is no
///     longer on screen. The guard then stood every arrow down for the rest of the panel's life,
///     with no search box visible to explain why.
///
/// A key monitor has neither problem: it sees the press before any window dispatches it, and it
/// can look at what actually holds focus and what is actually in it.
enum PanelArrowKey {
    static let leftKeyCode: UInt16 = 123
    static let rightKeyCode: UInt16 = 124
    static let downKeyCode: UInt16 = 125
    static let upKeyCode: UInt16 = 126

    /// -1 to walk towards the front of the row, +1 towards the back, nil when the press is not
    /// the panel's to take.
    ///
    /// Left/Up go backwards and Right/Down forwards, so it reads the same way whether the panel
    /// lays its cards out along the bottom of the screen or down the side of it.
    ///
    /// `inPanel` says the press was dispatched to the panel window. The panel's one editable field
    /// is the search box — a card being renamed, the item editor and the delete confirmation all
    /// raise the alert handshake, which the key monitor has already stood down for before it asks
    /// this — so an empty editable field here is an empty search box, and an empty search box has
    /// no caret worth moving.
    ///
    /// `suggestionsOpen` keeps ↑/↓ with the filter suggestion list while it is up. That list is
    /// driven by the search field's own key monitor, and two monitors claiming one press is a race
    /// with no defined winner.
    static func step(keyCode: UInt16,
                     modifiers: NSEvent.ModifierFlags,
                     firstResponder: NSResponder?,
                     inPanel: Bool,
                     suggestionsOpen: Bool) -> Int? {
        let delta: Int
        switch keyCode {
        case leftKeyCode, upKeyCode:    delta = -1
        case rightKeyCode, downKeyCode: delta = 1
        default: return nil
        }
        // Every arrow on a Mac keyboard arrives carrying `.numericPad` and `.function`, so neither
        // can count as a modifier here or this never fires at all. Caps Lock is not a binding
        // anyone makes either. What is left — ⌘, ⌥, ⌃, ⇧ — belongs to whoever bound it.
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard mods.isEmpty else { return nil }
        guard !suggestionsOpen else { return nil }
        if let text = firstResponder as? NSText, text.isEditable {
            guard inPanel, text.string.isEmpty else { return nil }
        }
        return delta
    }
}
