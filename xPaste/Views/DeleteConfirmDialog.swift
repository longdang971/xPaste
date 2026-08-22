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
@MainActor
final class DeleteConfirmPresenter: NSObject {
    static let shared = DeleteConfirmPresenter()

    private var panel: NSPanel?
    /// The window that had the keyboard before the question was asked — the clipboard bar, whose
    /// ⏎ / ⌫ / arrow shortcuts have to come back to life once the dialog goes away.
    private weak var previousKeyWindow: NSWindow?

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
            onConfirm: { [weak self] in
                self?.dismiss()
                onConfirm()
            }
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

        previousKeyWindow = NSApp.keyWindow
        self.panel = panel
        // Tells AppDelegate's key monitor to keep its hands off: while this is up, Escape must
        // cancel the question rather than close the panel out from under it.
        NotificationCenter.default.post(name: .clipboardAlertShown, object: nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.orderOut(nil)
        NotificationCenter.default.post(name: .clipboardAlertHidden, object: nil)
        // Hand the keyboard back to the bar, or its hidden ⏎ / ⌫ / arrow shortcuts stay dead for
        // the rest of the session.
        if let previous = previousKeyWindow, previous.isVisible {
            previous.makeKey()
        }
        previousKeyWindow = nil
    }

    @objc private func handlePanelWillHide() { dismiss() }

    /// The screen the bar is on, so the question doesn't open on a different display from the
    /// cards it is about.
    private func anchorScreen() -> NSScreen? {
        NSApp.keyWindow?.screen ?? NSScreen.main
    }
}

/// Borderless windows refuse the keyboard unless they say otherwise, and this one needs it for
/// ⏎ and Escape.
private final class DeleteConfirmPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
                // The width belongs on the *label*: outside, the button is given the width but
                // only the word itself answers a click.
                Button(action: onCancel) {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)

                Button(action: onConfirm) {
                    Text(confirmTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
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
