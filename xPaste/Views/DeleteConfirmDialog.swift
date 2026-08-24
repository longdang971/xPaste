import AppKit
import SwiftUI

/// The "are you sure?" for anything that destroys clipboard history.
///
/// A window of its own rather than SwiftUI's `.alert`, which presents *inside* the panel: it
/// desaturates everything behind it, so the very cards being asked about went grey and unreadable
/// at the moment the question was asked. This floats free, centred on the screen the panel is on —
/// the panel keeps its glass and its colour — which is also how Paste asks.
///
/// The window is a non-activating panel like the bar itself, so asking never pulls focus away from
/// the app the user is about to paste into.
///
/// It also never takes the *keyboard* from the bar, which is a stronger requirement than it sounds:
/// the bar's Liquid Glass follows its window's key state, so the instant this window became key the
/// whole bar darkened behind the question (measured: −7/255 on all three channels across the glass).
/// `NSGlassEffectView` has no `state` knob the way `NSVisualEffectView` does, and neither making
/// this a child window of the bar nor overriding `isKeyWindow` on the bar moved that number — the
/// only thing that did was leaving the bar key. So this window refuses key, and takes its ⏎ and
/// Escape from a local event monitor instead (see `installKeyMonitor`), which also has to swallow
/// the rest of the keyboard: with the bar still key, its ⏎ / ⌫ / ⌘1 shortcuts would otherwise stay
/// live underneath the question.
@MainActor
final class DeleteConfirmPresenter: NSObject {
    static let shared = DeleteConfirmPresenter()

    private var panel: NSPanel?
    /// What ⏎ (and the confirm button) runs. Held here rather than only in the SwiftUI view because
    /// the keyboard now arrives through a monitor rather than through the window.
    private var confirmAction: (() -> Void)?
    private var keyMonitor: Any?
    /// The window whose keyboard the monitor may speak for — the bar the question was asked from.
    /// Settings and the preview editor are the app's other windows, and typing in one of those must
    /// neither be swallowed nor able to answer this question.
    private weak var barWindow: NSWindow?

    private override init() {
        super.init()
        // Whatever takes the panel away while the question is up — Escape, a click outside, the
        // hotkey again — takes the question with it. Left on screen it would be asking about a
        // selection that no longer exists.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePanelWillHide),
            name: .panelWillHide, object: nil)
    }

    /// Asks, then runs `onConfirm` only if the user confirms.
    ///
    /// `message` is the whole question — the dialog has no separate body text, the same way the
    /// screenshot-worthy ones don't.
    func confirm(message: String,
                 confirmTitle: String,
                 onConfirm: @escaping () -> Void) {
        dismiss()

        let view = DeleteConfirmView(
            message: message,
            confirmTitle: confirmTitle,
            onCancel: { [weak self] in self?.dismiss() },
            onConfirm: { [weak self] in self?.runConfirm() }
        )

        let hosting = NSHostingView(rootView: view)
        let panel = DeleteConfirmPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        // An accessory app loses front constantly; without this the question would vanish the
        // moment the user's own app came back.
        panel.hidesOnDeactivate = false
        // Above the bar, which sits at `.statusBar`.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.center(on: anchorScreen())

        self.panel = panel
        self.confirmAction = onConfirm
        self.barWindow = NSApp.keyWindow
        // Tells AppDelegate's key monitor to keep its hands off: while this is up, Escape must
        // cancel the question rather than close the panel out from under it.
        NotificationCenter.default.post(name: .clipboardAlertShown, object: nil)
        installKeyMonitor()
        // Not `makeKeyAndOrderFront`: taking the keyboard is exactly what dimmed the bar.
        panel.orderFrontRegardless()
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        confirmAction = nil
        barWindow = nil
        removeKeyMonitor()
        panel.orderOut(nil)
        NotificationCenter.default.post(name: .clipboardAlertHidden, object: nil)
    }

    private func runConfirm() {
        let action = confirmAction
        dismiss()
        action?()
    }

    /// ⏎ confirms, Escape cancels, and nothing else gets through.
    ///
    /// The bar keeps the keyboard while the question is up, so every shortcut it owns — ⏎ to paste,
    /// ⌫ to delete again, ⌘1…9, the arrows — is still armed and pointed at the very cards being
    /// asked about. A question that can be answered by accident is worse than no question, so this
    /// eats the lot. ⌘Q is the one exception: quitting must not need an answer first.
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel != nil else { return event }
            guard event.window == nil || event.window === self.barWindow else { return event }
            switch event.keyCode {
            case 53:                       // Escape
                self.dismiss()
                return nil
            case 36, 76:                   // Return, keypad Enter
                self.runConfirm()
                return nil
            case 12 where event.modifierFlags.contains(.command):   // ⌘Q
                return event
            default:
                return nil
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @objc private func handlePanelWillHide() { dismiss() }

    /// The screen the bar is on, so the question doesn't open on a different display from the
    /// cards it is about.
    private func anchorScreen() -> NSScreen? {
        NSApp.keyWindow?.screen ?? NSScreen.main
    }
}

/// Refuses the keyboard on purpose — see the note on `DeleteConfirmPresenter`. Clicks still land:
/// a window that cannot become key is never asked to, so its buttons take the press directly.
private final class DeleteConfirmPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSWindow {
    /// Centred horizontally, and high enough that the panel at the bottom of the screen still
    /// reads as the thing being asked about — the placement AppKit's own `center()` uses, but on
    /// the screen given rather than always the main one.
    func center(on screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + (visible.height - frame.height) * 2 / 3
        ))
    }
}

private struct DeleteConfirmView: View {
    let message: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let cornerRadius: CGFloat = 18

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                DialogButton(title: "Cancel", prominent: false, action: onCancel)
                DialogButton(title: confirmTitle, prominent: true, action: onConfirm)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 280)
        .background(PanelGlassBackground(cornerRadius: cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }
}

/// A button drawn by hand rather than by AppKit.
///
/// AppKit's own buttons grey out in a window that isn't key, and this window never is — a stock
/// `.borderedProminent` confirm button rendered as a dead grey slab. These paint their own colour,
/// so the question looks the same as it always did.
private struct DialogButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: prominent ? .semibold : .regular))
                .foregroundColor(prominent ? .white : .primary)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
        .buttonStyle(DialogButtonStyle(prominent: prominent, hovered: hovered))
        .onHover { hovered = $0 }
    }
}

private struct DialogButtonStyle: ButtonStyle {
    let prominent: Bool
    let hovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func fill(pressed: Bool) -> Color {
        if prominent {
            return Color.accentColor.opacity(pressed ? 0.75 : (hovered ? 0.9 : 1))
        }
        return Color.primary.opacity(pressed ? 0.22 : (hovered ? 0.16 : 0.10))
    }
}
