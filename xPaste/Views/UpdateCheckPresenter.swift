import AppKit
import SwiftUI

/// The small panel for the results that do not need the big window: checking, already up to date,
/// or the check failed.
///
/// `UpdateWindowView`, with its scrollable "What's New" box, opens only when there is genuinely
/// something new — putting all of that on screen to say "you have the latest version" is far more
/// than the sentence is worth.
///
/// One panel serves all three phases and changes in place. Pressing the menu item shows it
/// immediately with a spinner, and it becomes the answer; building a new panel per phase makes an
/// unpleasant flicker whenever the server answers quickly.
@MainActor
final class UpdateCheckPresenter: NSObject {

    enum Phase: Equatable {
        case checking
        case upToDate(version: String)
        case failed(message: String)
    }

    /// The panel's contents, kept apart from the presenter so SwiftUI redraws on a phase change
    /// without the `NSHostingView` being rebuilt.
    fileprivate final class Model: ObservableObject {
        @Published var phase: Phase = .checking
    }

    private let model = Model()
    private var panel: NSPanel?

    /// `AppDelegate` is not actor-isolated, so it cannot build a `@MainActor` type in a stored
    /// property. Constructing one touches nothing isolated.
    override nonisolated init() { super.init() }

    /// Shows the panel, building it the first time, and puts it on `phase`.
    func show(_ phase: Phase) {
        model.phase = phase
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 260),
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // xPaste is an accessory app that loses front constantly; without this the answer would
        // vanish the moment the user clicked back into whatever they were doing.
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.delegate = self

        let view = UpdateCheckView(model: model, onDismiss: { [weak self] in self?.dismiss() })
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        return panel
    }
}

extension UpdateCheckPresenter: NSWindowDelegate {
    /// Closed with the red button: forget it, so the next check builds a fresh one.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let closing = notification.object as? NSPanel, closing === panel else { return }
            panel = nil
        }
    }
}

private struct UpdateCheckView: View {
    @ObservedObject fileprivate var model: UpdateCheckPresenter.Model
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(isFailure ? Color.red : Color.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .checking = model.phase {
                ProgressView().controlSize(.small)
            } else {
                // The width belongs on the *label*, not the `Button`: outside, the button is given
                // the width but the part that responds to a click stays as narrow as the word "OK".
                Button { onDismiss() } label: {
                    Text("OK").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(width: 320)
    }

    private var title: String {
        switch model.phase {
        case .checking: return "Checking for updates…"
        case .upToDate: return "You're up to date!"
        case .failed:   return "Couldn't check for updates"
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .checking:
            return nil
        case let .upToDate(version):
            return "xPaste \(version) is the latest version."
        case let .failed(message):
            return message
        }
    }

    private var isFailure: Bool {
        if case .failed = model.phase { return true }
        return false
    }
}
