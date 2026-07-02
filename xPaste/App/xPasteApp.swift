import SwiftUI

@main
struct xPasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
