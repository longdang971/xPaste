import Foundation
import ServiceManagement

/// The app's "start at login" registration, in one place.
///
/// Settings and the onboarding sheet each drive `SMAppService.mainApp` directly through a toggle;
/// this wrapper exists for the callers that only need the answer — the panel's "Run in Background"
/// notice, which appears until the app is registered.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers the app, ignoring the "already registered" case. A failure here leaves the notice
    /// on screen, which is the honest outcome: nothing was enabled.
    static func enable() {
        guard !isEnabled else { return }
        try? SMAppService.mainApp.register()
    }
}
