import Foundation

/// Keeps the Save dialog from opening with the extension highlighted.
///
/// The dialog proposes a bare extension — `.png` — so that the insertion point lands where the user
/// is about to type. `NSSavePanel` selects whatever name it is handed, and a name that is *only* an
/// extension reads to AppKit as a dotfile with no extension to hold back, so the whole of `.png`
/// comes up selected and the first keystroke wipes it.
///
/// Nothing in AppKit collapses that selection. Since macOS 26 the dialog is drawn by
/// `com.apple.appkit.xpc.openAndSavePanelService` even when the app is not sandboxed, so its text
/// view belongs to another process; Accessibility is no way in either, because a process may not
/// read its own focused element (`AXUIElementCopyAttributeValue` answers `kAXErrorNotImplemented`).
/// What is left is a synthetic left arrow, which moves a selection to its own start and so leaves
/// the caret in front of the dot without changing a character.
///
/// Two things about *when* to press had to be measured, because both guesses were wrong.
///
/// The press cannot be scheduled with `DispatchQueue.main`. `runModal` is called from inside a
/// main-queue block, and the main queue is serial — nothing queued behind that block runs until it
/// returns, which is after the dialog has closed. A traced run showed the whole nudge executing
/// against a dialog that was no longer there. It has to be a run-loop timer, added to the modal
/// panel's mode, which is what `AppDelegate` gives it.
///
/// The press also cannot be gated on the app looking ready, because none of those signals can be
/// asked here. The panel is out of process, so `isVisible` on it stays `false` while it is on
/// screen; and the bar the save was started from is a `nonactivatingPanel`, so xPaste never becomes
/// the active application at all — `NSApp.isActive` flickers true for one tick and drops, and
/// `NSWorkspace.frontmostApplication` names the app that was already in front. The dialog takes
/// keystrokes regardless of all of it.
///
/// So the press goes out unconditionally on a short tick for as long as the dialog is up. Pressing
/// again once the caret is at the front does nothing, which is what makes repeating safe; repeating
/// is what covers a field editor in another process that was not ready for the first one.
enum SaveNameCaret {

    /// What one tick should do.
    enum Step: Equatable {
        /// Press the left arrow, then tick again.
        case press
        /// Stop: the caret is placed, or is no longer ours to place.
        case stop
    }

    static let tickInterval: TimeInterval = 0.1
    /// The first press that lands does the work; the rest cover a field editor that was not ready
    /// yet. Short enough that presses cannot still be going out once somebody has had time to click
    /// somewhere else in the dialog.
    static let pressLimit = 6

    static func step(presses: Int, currentName: String, suggestedName: String) -> Step {
        guard presses < pressLimit else { return .stop }
        // Anything typed is the user's, and the caret goes wherever they put it.
        guard currentName == suggestedName else { return .stop }
        return .press
    }
}
