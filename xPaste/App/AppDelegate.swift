import AppKit
import Carbon.HIToolbox
import SwiftUI

private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    NotificationCenter.default.post(name: .toggleClipboard, object: nil)
    return noErr
}

extension Notification.Name {
    static let toggleClipboard      = Notification.Name("com.user.xPaste.toggleClipboard")
    static let pasteClipboardItem   = Notification.Name("com.user.xPaste.pasteItem")
    static let panelDidOpen         = Notification.Name("com.user.xPaste.panelDidOpen")
    static let clipboardAlertShown  = Notification.Name("com.user.xPaste.alertShown")
    static let clipboardAlertHidden = Notification.Name("com.user.xPaste.alertHidden")
    static let panelWillHide        = Notification.Name("com.user.xPaste.panelWillHide")
    static let panelDidHide         = Notification.Name("com.user.xPaste.panelDidHide")
    static let cmdClickInPanel      = Notification.Name("com.user.xPaste.cmdClickInPanel")
    static let doubleClickInPanel   = Notification.Name("com.user.xPaste.doubleClickInPanel")
    static let hotkeyChanged        = Notification.Name("com.user.xPaste.hotkeyChanged")
    static let openSettingsWindow   = Notification.Name("com.user.xPaste.openSettingsWindow")
    static let menuBarIconChanged   = Notification.Name("com.user.xPaste.menuBarIconChanged")
    static let screenSharingVisibilityChanged = Notification.Name("com.user.xPaste.screenSharingVisibilityChanged")
}

private class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {

        case .leftMouseDown:
            if event.modifierFlags.contains(.command) {
                NotificationCenter.default.post(
                    name: .cmdClickInPanel,
                    object: nil,
                    userInfo: ["locationInWindow": event.locationInWindow]
                )
                return
            }
            if event.clickCount == 2 {
                NotificationCenter.default.post(
                    name: .doubleClickInPanel,
                    object: nil,
                    userInfo: ["locationInWindow": event.locationInWindow]
                )
                return
            }
            let loc = event.locationInWindow
            if let hit = contentView?.hitTest(loc),
               !(hit is NSTextView),
               loc.y < frame.height - 75 {
                makeFirstResponder(nil)
            }

        case .scrollWheel:
            let pos = UserDefaults.standard.string(forKey: "panelPosition") ?? "bottom"
            let isHorizontalList = pos == "bottom" || pos == "top"
            if isHorizontalList {
                let dy = event.scrollingDeltaY
                let dx = event.scrollingDeltaX
                if abs(dy) > 0, abs(dx) <= abs(dy) * 0.3,
                   let sv = contentView.flatMap({ $0.firstDescendantScrollView }) {
                    let visible = sv.documentVisibleRect
                    let docWidth = sv.documentView?.bounds.width ?? visible.maxX
                    let maxX = max(0, docWidth - visible.width)
                    let newX = (visible.origin.x - dy).clamped(to: 0...maxX)
                    sv.documentView?.scroll(NSPoint(x: newX, y: 0))
                    return
                }
            }

        default:
            break
        }
        super.sendEvent(event)
    }
}

private extension NSView {
    var firstDescendantScrollView: NSScrollView? {
        if let sv = self as? NSScrollView { return sv }
        for sub in subviews {
            if let found = sub.firstDescendantScrollView { return found }
        }
        return nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: ClipboardPanel?
    private var panelVisible = false
    private var hotKeyRef: EventHotKeyRef?
    private var settingsWindow: NSWindow?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var alertIsPresented = false
    private var frameAnimTimer: Timer?
    /// The screen the panel was last shown on. Captured once per show so the frame, the
    /// off-screen slide target, and the card scale are all computed against the same display.
    private var activeScreen: NSScreen?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.register(defaults: [
            "showDuringScreenSharing": true,
            "ignoreConfidentialContent": true,
            "ignoreTransientContent": true,
            // Passwords.app and Keychain Access are excluded out of the box.
            "ignoredAppBundleIDs": ["com.apple.Passwords", "com.apple.keychainaccess"],
        ])
        AppearanceManager.applyStored()
        setupStatusItem()
        setupPanel()
        setupHotKey()
        ClipboardMonitor.shared.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleToggleClipboard),
            name: .toggleClipboard, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePasteItem),
            name: .pasteClipboardItem, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAlertShown),
            name: .clipboardAlertShown, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAlertHidden),
            name: .clipboardAlertHidden, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettingsWindow, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateMenuBarVisibility),
            name: .menuBarIconChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateScreenSharingVisibility),
            name: .screenSharingVisibilityChanged, object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWillPowerOff),
            name: NSWorkspace.willPowerOffNotification, object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.promptAccessibilityOnFirstLaunchIfNeeded()
        }

    }

    private func promptAccessibilityOnFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        let key = "didPromptAccessibility"
        guard !defaults.bool(forKey: key) else { return }

        guard !AccessibilityPermission.isTrusted else {
            defaults.set(true, forKey: key)
            return
        }
        defaults.set(true, forKey: key)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enable Accessibility for xPaste"
        alert.informativeText = "xPaste needs Accessibility permission to paste items into other apps (it simulates ⌘V).\n\nOpen System Settings › Privacy & Security › Accessibility and turn on xPaste."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.requestSystemPrompt()
            AccessibilityPermission.openSystemSettings()
        }
    }

    @objc private func handleWillPowerOff() {
        if UserDefaults.standard.bool(forKey: "clearOnLogout") {
            ClipboardStore.shared.clearAll()
        }
    }

    @objc private func handleWillSleep() {
        if UserDefaults.standard.bool(forKey: "clearOnLogout") {
            ClipboardStore.shared.clearAll()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardMonitor.shared.stop()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    }

    // Re-opening the app from Finder/Launchpad/Dock while it's already running (an accessory app
    // won't launch a second instance) routes here instead. Show the panel so double-clicking the
    // app icon in /Applications behaves like the hotkey.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsWindow?.isVisible == true { return true }
        if !panelVisible { showPanel() }
        return true
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        let icon = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "xPaste")
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        icon?.accessibilityDescription = "xPaste"
        button.image = icon
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusBarButtonClicked)
        button.target = self
        updateMenuBarVisibility()
    }

    @objc private func updateMenuBarVisibility() {
        statusItem?.isVisible = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            togglePanel()
        }
    }

    private func showRightClickMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func setupPanel() {
        let rootView = ContentView().environmentObject(ClipboardStore.shared)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = CGColor.clear
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true

        let p = ClipboardPanel(
            contentRect: panelFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = UserDefaults.standard.bool(forKey: "showDuringScreenSharing") ? .readOnly : .none
        p.contentView = hostingView
        self.panel = p
    }

    @objc private func updateScreenSharingVisibility() {
        panel?.sharingType = UserDefaults.standard.bool(forKey: "showDuringScreenSharing") ? .readOnly : .none
    }

    private func panelFrame() -> NSRect {
        guard let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 900, height: 300)
        }
        let position = UserDefaults.standard.string(forKey: "panelPosition") ?? "bottom"
        let sf = screen.frame
        let vf = screen.visibleFrame
        let hThickness = PanelLayout.horizontalThickness(for: screen)
        let vThickness = PanelLayout.verticalThickness(for: screen)

        switch position {
        case "top":
            return NSRect(x: sf.minX, y: sf.maxY - hThickness,
                          width: sf.width, height: hThickness)
        case "left":
            return NSRect(x: sf.minX, y: sf.minY,
                          width: vThickness, height: sf.height)
        case "right":
            return NSRect(x: sf.maxX - vThickness, y: sf.minY,
                          width: vThickness, height: sf.height)
        default:
            return NSRect(x: sf.minX, y: vf.minY,
                          width: sf.width, height: hThickness)
        }
    }

    @objc func togglePanel(_ sender: AnyObject? = nil) {
        if panelVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        ClipboardStore.shared.pruneExpired()
        previousApp = NSWorkspace.shared.frontmostApplication
        ClipboardStore.shared.targetAppName = previousApp?.localizedName
        guard let panel else { return }
        // Lock in the display now (before makeKey can flip NSScreen.main) and publish the
        // matching card scale, so the bar and the cards are sized against the same screen.
        activeScreen = NSScreen.main ?? NSScreen.screens.first
        ClipboardStore.shared.panelScale = PanelLayout.scale(for: activeScreen)
        let target = panelFrame()
        let start  = offscreenFrame(for: target)

        panelVisible = true
        addMonitors()

        panel.setFrame(start, display: false, animate: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        // Route key events into the SwiftUI content right away so ⌘A / arrow keys / ⏎ work the
        // instant the panel appears, without first clicking a card to establish first responder.
        panel.makeFirstResponder(panel.contentView)
        NotificationCenter.default.post(name: .panelDidOpen, object: nil)

        // Start the slide on the NEXT runloop tick so the off-screen `start` frame is committed
        // and painted first — otherwise the very first open can begin mid-way (from the middle).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelVisible, self.panel != nil else { return }
            self.slidePanel(from: start, to: target, duration: 0.11, easeOut: true)
        }
    }

    private func hidePanel() {
        guard panelVisible else { return }
        NotificationCenter.default.post(name: .panelWillHide, object: nil)
        removeMonitors()
        panelVisible = false
        guard let p = panel else { return }

        let end = offscreenFrame(for: panelFrame())
        slidePanel(from: p.frame, to: end, duration: 0.10, easeOut: false) { [weak self] in
            guard self?.panelVisible == false else { return }
            self?.panel?.orderOut(nil)
            // Panel is now off-screen and unmounted; safe to run deferred store mutations
            // (e.g. moveToTop after a paste) without freezing the close animation.
            NotificationCenter.default.post(name: .panelDidHide, object: nil)
        }
    }

    private func slidePanel(from start: NSRect, to end: NSRect, duration: TimeInterval,
                            easeOut: Bool, completion: (() -> Void)? = nil) {
        guard let p = panel else { completion?(); return }
        frameAnimTimer?.invalidate()
        p.setFrameOrigin(start.origin)
        let begin = Date()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self, let p = self.panel else { t.invalidate(); return }
            let raw = min(1, Date().timeIntervalSince(begin) / duration)
            let e = easeOut ? (1 - (1 - raw) * (1 - raw)) : (raw * raw)
            let x = start.origin.x + (end.origin.x - start.origin.x) * e
            let y = start.origin.y + (end.origin.y - start.origin.y) * e
            p.setFrameOrigin(NSPoint(x: x, y: y))
            if raw >= 1 {
                t.invalidate()
                self.frameAnimTimer = nil
                completion?()
            }
        }
        frameAnimTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func offscreenFrame(for frame: NSRect) -> NSRect {
        let pos = UserDefaults.standard.string(forKey: "panelPosition") ?? "bottom"
        var f = frame
        switch pos {
        case "top":   f.origin.y = frame.maxY
        case "left":  f.origin.x = frame.minX - frame.width
        case "right": f.origin.x = frame.maxX
        default:      f.origin.y = frame.minY - frame.height
        }
        return f
    }

    private func addMonitors() {
        guard mouseMonitor == nil else { return }

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if let button = self.statusItem?.button, let win = button.window {
                if win.convertToScreen(button.frame).contains(NSEvent.mouseLocation) { return }
            }
            self.hidePanel()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if self.alertIsPresented { return event }
                self.hidePanel()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "," {
                self.hidePanel()
                self.openSettings()
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        if let m = keyMonitor   { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    @objc private func handleAlertShown()  { alertIsPresented = true  }
    @objc private func handleAlertHidden() { alertIsPresented = false }

    @objc private func handleToggleClipboard() {
        togglePanel()
    }

    @objc private func handlePasteItem() {
        guard AccessibilityPermission.isTrusted else {
            hidePanel()
            AccessibilityPermission.requestSystemPrompt()
            AccessibilityPermission.openSystemSettings()
            return
        }
        let target = previousApp
        let targetPID = target?.processIdentifier ?? 0
        // Slide the panel closed (down) and refocus the target app, then post ⌘V after a short
        // settle delay. The reorder-freeze that used to make this janky is fixed, so the close
        // animation stays smooth even during a paste.
        hidePanel()
        target?.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            let src = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags   = .maskCommand
            if targetPID > 0 {
                keyDown?.postToPid(targetPID)
                keyUp?.postToPid(targetPID)
            } else {
                keyDown?.post(tap: .cghidEventTap)
                keyUp?.post(tap: .cghidEventTap)
            }
        }
    }

    @objc private func openSettings() {
        if panelVisible { hidePanel() }
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView().environmentObject(ClipboardStore.shared)
            )
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 800, height: 480))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventSpec,
            nil,
            nil
        )

        registerHotKeyFromDefaults()

        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeyChanged),
            name: .hotkeyChanged, object: nil
        )
    }

    @objc private func hotkeyChanged() { registerHotKeyFromDefaults() }

    private func registerHotKeyFromDefaults() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        let keyCode = UserDefaults.standard.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_V
        let modifiers = UserDefaults.standard.object(forKey: "hotkeyModifiers") as? Int ?? (cmdKey | shiftKey)
        let hotKeyID = EventHotKeyID(signature: 0x434C4D47, id: 1)
        RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
    }
}

// MARK: - Adaptive panel sizing

/// Keeps the panel (and its cards) at a pleasant proportion across screens of
/// different logical heights. On a tall screen `scale == 1` (the reference
/// design); on a shorter one (e.g. a 1080-point Full-HD or a default-scaled 4K)
/// it shrinks so the bar never eats an oversized slice of the screen.
enum PanelLayout {
    /// Card design size at scale 1 (matches ClipboardItemCard's base frame).
    static let cardBaseHeight: CGFloat = 240
    static let cardBaseWidth: CGFloat = 250
    /// Fixed chrome around the horizontal card row (toolbar + divider + list padding).
    static let horizontalChrome: CGFloat = 80
    /// Fixed chrome around the vertical card column (horizontal list padding + slack).
    static let verticalChrome: CGFloat = 70
    /// Screen height (points) at/above which the full-size design is used.
    static let referenceScreenHeight: CGFloat = 1360
    static let minScale: CGFloat = 0.8

    static func scale(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 1 }
        return min(1.0, max(minScale, screen.frame.height / referenceScreenHeight))
    }

    /// Thickness of a top/bottom bar (its height).
    static func horizontalThickness(for screen: NSScreen?) -> CGFloat {
        (horizontalChrome + cardBaseHeight * scale(for: screen)).rounded()
    }

    /// Thickness of a left/right bar (its width).
    static func verticalThickness(for screen: NSScreen?) -> CGFloat {
        (verticalChrome + cardBaseWidth * scale(for: screen)).rounded()
    }
}

private struct PanelScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Uniform scale applied to cards so they stay proportional to the panel.
    var panelScale: CGFloat {
        get { self[PanelScaleKey.self] }
        set { self[PanelScaleKey.self] = newValue }
    }
}
