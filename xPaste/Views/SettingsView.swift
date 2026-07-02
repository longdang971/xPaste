import SwiftUI
import AppKit
import ServiceManagement
import Carbon.HIToolbox
import UniformTypeIdentifiers

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let window = v?.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum AppearanceManager {
    static func apply(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }

    static func applyStored() {
        apply(UserDefaults.standard.string(forKey: "appearanceMode") ?? "system")
    }
}

struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, privacy, appearance, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:    return "General"
            case .privacy:    return "Privacy"
            case .appearance: return "Appearance"
            case .about:      return "About"
            }
        }
        var icon: String {
            switch self {
            case .general:    return "gearshape.fill"
            case .privacy:    return "hand.raised.fill"
            case .appearance: return "paintbrush.fill"
            case .about:      return "info.circle.fill"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .zIndex(1)
            content
        }
        .frame(width: 800, height: 480)
        .background(WindowConfigurator())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 36)
            ForEach(Tab.allCases) { t in
                sidebarRow(t)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .shadow(color: .black.opacity(0.14), radius: 6, x: 1, y: 0)
    }

    private func sidebarRow(_ t: Tab) -> some View {
        let selected = tab == t
        return HStack(spacing: 10) {
            Image(systemName: t.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20)
            Text(t.title)
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { tab = t }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(tab.title)
                    .font(.system(size: 26, weight: .bold))
                    .padding(.bottom, -4)

                switch tab {
                case .general:    GeneralTab()
                case .privacy:    PrivacyTab()
                case .appearance: AppearanceTab()
                case .about:      AboutTab()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct CardDivider: View {
    var body: some View { Divider().padding(.leading, 14) }
}

private struct AccessibilityWarningBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility permission required")
                    .font(.system(size: 13, weight: .semibold))
                Text("xPaste can't paste into other apps until you turn it on in System Settings › Privacy & Security › Accessibility.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open") {
                AccessibilityPermission.requestSystemPrompt()
                AccessibilityPermission.openSystemSettings()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5)
        )
    }
}

private func sectionHeader(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
}

private struct GeneralTab: View {
    @EnvironmentObject private var store: ClipboardStore
    @State private var launchAtLogin = false
    @State private var showEraseConfirm = false
    @AppStorage("keepHistoryIndex") private var keepHistoryIndex: Int = 4
    @AppStorage("clearOnLogout") private var clearOnLogout: Bool = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @AppStorage("clipboardScanInterval") private var scanInterval: Double = 0.1
    @AppStorage("alwaysPastePlainText") private var alwaysPastePlainText: Bool = false
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let keepLabels = ["Day", "Week", "Month", "Year", "Forever"]
    private var keepDescription: String {
        keepHistoryIndex == 4
            ? "Items are kept forever until you remove them."
            : "Unpinned items older than 1 \(keepLabels[keepHistoryIndex].lowercased()) are removed automatically. Pinned items are always kept."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !accessibilityTrusted {
                AccessibilityWarningBanner()
            }
            SettingsCard {
                Row(title: "Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { newValue in
                            do {
                                if newValue { try SMAppService.mainApp.register() }
                                else { try SMAppService.mainApp.unregister() }
                            } catch { print("Launch at login error: \(error)") }
                        }
                }
                CardDivider()
                Row(title: "Show menu bar icon",
                    subtitle: "When hidden, open the panel with ⌘⇧V.") {
                    Toggle("", isOn: $showMenuBarIcon)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: showMenuBarIcon) { _ in
                            NotificationCenter.default.post(name: .menuBarIconChanged, object: nil)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Shortcut")
                SettingsCard {
                    Row(title: "Show clipboard panel",
                        subtitle: "Click, then press the key combination you want.") {
                        HotkeyRecorderButton()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Keep History")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(keepHistoryIndex) },
                                set: { keepHistoryIndex = Int($0.rounded()) }
                            ),
                            in: 0...4, step: 1
                        )
                        HStack(spacing: 0) {
                            ForEach(Array(keepLabels.enumerated()), id: \.offset) { idx, label in
                                Text(label)
                                    .font(.system(size: 10, weight: keepHistoryIndex == idx ? .bold : .regular))
                                    .foregroundStyle(keepHistoryIndex == idx ? Color.accentColor : Color.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        Text(keepDescription)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)

                    CardDivider()

                    Row(title: "Clear history on sleep or logout",
                        subtitle: "Erase every item (including pinned) when your Mac goes to sleep, or when you log out, restart, or shut down.") {
                        Toggle("", isOn: $clearOnLogout)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .onChange(of: keepHistoryIndex) { _ in store.pruneExpired() }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Clipboard")
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Scan rate").font(.system(size: 13))
                            Spacer()
                            Text(String(format: "%.0f ms", scanInterval * 1000))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $scanInterval, in: 0.05...0.5, step: 0.05)
                            .onChange(of: scanInterval) { _ in ClipboardMonitor.shared.restart() }
                        HStack {
                            Text("Faster (catch rapid copies)").font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                            Text("Lower CPU").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text("How often xPaste checks the clipboard. A lower value catches fast, back-to-back ⌘C copies but uses a little more CPU. Default is 100 ms.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)

                    CardDivider()

                    Row(title: "Always paste as Plain Text",
                        subtitle: "Remove formatting so items are always pasted as unformatted text.") {
                        Toggle("", isOn: $alwaysPastePlainText)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Storage")
                SettingsCard {
                    Row(title: "Items stored",
                        subtitle: "\(store.items.filter(\.isPinned).count) pinned") {
                        Text("\(store.items.count)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    CardDivider()
                    Row(title: "Erase History",
                        subtitle: "Removes all unpinned items.") {
                        Button("Erase History…", role: .destructive) { showEraseConfirm = true }
                    }
                }
            }
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            accessibilityTrusted = AccessibilityPermission.isTrusted
        }
        .onReceive(permissionTimer) { _ in
            let trusted = AccessibilityPermission.isTrusted
            if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        }
        .confirmationDialog(
            "Delete all unpinned clipboard history?",
            isPresented: $showEraseConfirm,
            titleVisibility: .visible
        ) {
            Button("Erase History", role: .destructive) { store.clearUnpinned() }
        }
    }
}

private struct AppearanceTab: View {
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("panelPosition") private var panelPosition: String = "bottom"
    @AppStorage("linkPreviewEnabled") private var linkPreviewEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Theme")
                SettingsCard {
                    Row(title: "Appearance",
                        subtitle: "“System” follows your Mac’s light or dark setting.") {
                        Picker("", selection: $appearanceMode) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                        .onChange(of: appearanceMode) { AppearanceManager.apply($0) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Panel")
                SettingsCard {
                    Row(title: "Panel position") {
                        Picker("", selection: $panelPosition) {
                            Text("Bottom").tag("bottom")
                            Text("Top").tag("top")
                            Text("Left").tag("left")
                            Text("Right").tag("right")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }
                    CardDivider()
                    Row(title: "Load link previews",
                        subtitle: "Fetch title and image for copied web links.") {
                        Toggle("", isOn: $linkPreviewEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
            }
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("xPaste").font(.system(size: 15, weight: .semibold))
                        Text("Version 1.0.0").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Powered by LQ Team").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
            }
        }
    }
}

private struct PrivacyTab: View {
    @AppStorage("showDuringScreenSharing")  private var showDuringScreenSharing = true
    @AppStorage("ignoreConfidentialContent") private var ignoreConfidential = true
    @AppStorage("ignoreTransientContent")    private var ignoreTransient = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard {
                Row(title: "Show during screen sharing",
                    subtitle: "Allow xPaste to appear to others when you share your screen.") {
                    Toggle("", isOn: $showDuringScreenSharing)
                        .labelsHidden().toggleStyle(.switch)
                        .onChange(of: showDuringScreenSharing) { _ in
                            NotificationCenter.default.post(name: .screenSharingVisibilityChanged, object: nil)
                        }
                }
                CardDivider()
                Row(title: "Ignore confidential content",
                    subtitle: "Don’t save passwords and sensitive data when detected.") {
                    Toggle("", isOn: $ignoreConfidential).labelsHidden().toggleStyle(.switch)
                }
                CardDivider()
                Row(title: "Ignore transient content",
                    subtitle: "Don’t save temporary data generated by other apps.") {
                    Toggle("", isOn: $ignoreTransient).labelsHidden().toggleStyle(.switch)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Ignore Applications")
                Text("Don’t save content copied from the applications below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                IgnoredAppsList()
            }
        }
    }
}

private struct IgnoredAppInfo: Identifiable {
    let bundleID: String
    var id: String { bundleID }
    let name: String
    let icon: NSImage
}

private struct IgnoredAppsList: View {
    @State private var apps: [IgnoredAppInfo] = []
    @State private var selection: String?

    private let key = "ignoredAppBundleIDs"

    var body: some View {
        SettingsCard {
            VStack(spacing: 0) {
                if apps.isEmpty {
                    Text("No applications added")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                } else {
                    ForEach(apps) { app in
                        HStack(spacing: 10) {
                            Image(nsImage: app.icon).resizable().frame(width: 20, height: 20)
                            Text(app.name).font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(selection == app.bundleID ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = app.bundleID }
                        if app.id != apps.last?.id { CardDivider() }
                    }
                }

                Divider()

                HStack(spacing: 2) {
                    Button(action: addApp) {
                        Image(systemName: "plus").frame(width: 26, height: 20)
                    }
                    .buttonStyle(.borderless)
                    Divider().frame(height: 14)
                    Button(action: removeSelected) {
                        Image(systemName: "minus").frame(width: 26, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        let ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        apps = ids.map { bid in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
            let name = url.map {
                FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
            } ?? bid
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
            icon.size = NSSize(width: 20, height: 20)
            return IgnoredAppInfo(bundleID: bid, name: name, icon: icon)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url,
              let bid = Bundle(url: url)?.bundleIdentifier else { return }
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !ids.contains(bid) {
            ids.append(bid)
            UserDefaults.standard.set(ids, forKey: key)
        }
        reload()
    }

    private func removeSelected() {
        guard let sel = selection else { return }
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        ids.removeAll { $0 == sel }
        UserDefaults.standard.set(ids, forKey: key)
        selection = nil
        reload()
    }
}

private struct HotkeyRecorderButton: View {
    @AppStorage("hotkeyDisplay") private var display: String = "⌘⇧V"
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "Type shortcut…" : display)
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .tint(recording ? Color.accentColor : nil)
        .onDisappear(perform: stop)
    }

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

        UserDefaults.standard.set(Int(event.keyCode), forKey: "hotkeyKeyCode")
        UserDefaults.standard.set(carbon, forKey: "hotkeyModifiers")
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
