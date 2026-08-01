import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The activation shortcut xPaste ships with. AppDelegate falls back to these when the
/// user hasn't recorded one, so resetting the recorder just clears the stored keys.
enum HotkeyDefaults {
    static let keyCode = kVK_ANSI_V
    static let modifiers = cmdKey | shiftKey
    static let display = "⌘⇧V"

    static let keyCodeKey = "hotkeyKeyCode"
    static let modifiersKey = "hotkeyModifiers"
    static let displayKey = "hotkeyDisplay"
}

/// Records the global activation shortcut.
///
/// Shared by the Settings window and Quick Start so both write the same defaults and post
/// the same change notification; only the chrome differs.
struct HotkeyRecorderButton: View {
    enum Style {
        /// Compact bordered button that sits in a Settings row.
        case settings
        /// Wider field with a reset control, used in Quick Start.
        case onboarding
    }

    var style: Style = .settings

    @AppStorage(HotkeyDefaults.displayKey) private var display: String = HotkeyDefaults.display
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Group {
            switch style {
            case .settings:   settingsButton
            case .onboarding: onboardingField
            }
        }
        .onDisappear(perform: stop)
    }

    private var settingsButton: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .tint(recording ? Color.accentColor : nil)
    }

    private var onboardingField: some View {
        HStack(spacing: 0) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(recording ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: reset) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reset to \(HotkeyDefaults.display)")
        }
        .frame(width: 150)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(recording ? Color.accentColor : Color(nsColor: .separatorColor),
                              lineWidth: recording ? 1.5 : 0.5)
        )
    }

    private var label: String { recording ? "Type shortcut…" : display }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    /// Drops the recorded shortcut so the built-in ⌘⇧V takes over again. Deliberately a
    /// reset rather than a clear: with no shortcut at all and the menu bar icon hidden,
    /// there would be no way left to open the panel.
    private func reset() {
        stop()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: HotkeyDefaults.keyCodeKey)
        defaults.removeObject(forKey: HotkeyDefaults.modifiersKey)
        display = HotkeyDefaults.display
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stop(); return }

        var carbon = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option)  { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift)   { carbon |= shiftKey }

        guard carbon != 0,
              let chars = event.charactersIgnoringModifiers, !chars.isEmpty
        else { return }

        UserDefaults.standard.set(Int(event.keyCode), forKey: HotkeyDefaults.keyCodeKey)
        UserDefaults.standard.set(carbon, forKey: HotkeyDefaults.modifiersKey)
        display = symbols(flags) + chars.uppercased()
        stop()
        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    private func symbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }
}
