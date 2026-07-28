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
    static let pasteNumberedItem    = Notification.Name("com.user.xPaste.pasteNumberedItem")
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
        warmPanel()

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
        hostingView.layer?.cornerRadius = PanelLayout.cornerRadius
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

    /// Builds the panel's SwiftUI tree once, off-screen, shortly after launch.
    ///
    /// Cold, the first open measured 71–89ms against 38–46ms warm: that gap is SwiftUI creating
    /// the whole view tree on the critical path between the hotkey and the slide starting.
    /// Doing it here moves the cost to launch, where nobody is waiting on it.
    private func warmPanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, !self.panelVisible else { return }
            // Fully transparent for the duration: ordering the panel in — even at an off-screen
            // frame — flashed it on screen for a frame at launch. Alpha 0 makes the warm-up
            // invisible no matter how the window server decides to place it.
            panel.alphaValue = 0
            panel.setFrame(self.offscreenFrame(for: self.panelFrame()), display: false, animate: false)
            panel.orderFrontRegardless()
            panel.displayIfNeeded()
            // Establish first responder here too: NSWindow remembers it across orderOut, so the
            // per-open call below finds it already set and costs nothing.
            panel.makeFirstResponder(panel.contentView)
            panel.orderOut(nil)
            panel.alphaValue = 1
            if self.settingsWindow?.isVisible != true {
                ClipboardStore.shared.publishingSuppressed = true
            }
        }
    }

    @objc private func updateScreenSharingVisibility() {
        panel?.sharingType = UserDefaults.standard.bool(forKey: "showDuringScreenSharing") ? .readOnly : .none
    }

    private func panelFrame() -> NSRect {
        guard let screen = activeScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 900, height: 300)
        }
        let position = UserDefaults.standard.string(forKey: "panelPosition") ?? "bottom"
        let hThickness = PanelLayout.horizontalThickness(for: screen)
        let vThickness = PanelLayout.verticalThickness(for: screen)
        // Float the bar with a uniform gap so it reads as a detached panel instead of
        // hugging the bezel. The axis the bar spans is measured against the full screen —
        // a Dock parked on that edge must not push the bar off-centre — while the axis it
        // is anchored on uses the visible frame, so it never sits under the menu bar or Dock.
        let inset = PanelLayout.screenInset
        let sf = screen.frame
        let vf = screen.visibleFrame
        let hSpan = sf.insetBy(dx: inset, dy: 0)   // left/right extent of a top/bottom bar
        let vSpan = vf.insetBy(dx: 0, dy: inset)   // top/bottom extent of a left/right bar

        switch position {
        case "top":
            return NSRect(x: hSpan.minX, y: vf.maxY - inset - hThickness,
                          width: hSpan.width, height: hThickness)
        case "left":
            return NSRect(x: vf.minX + inset, y: vSpan.minY,
                          width: vThickness, height: vSpan.height)
        case "right":
            return NSRect(x: vf.maxX - inset - vThickness, y: vSpan.minY,
                          width: vThickness, height: vSpan.height)
        default:
            return NSRect(x: hSpan.minX, y: vf.minY + inset,
                          width: hSpan.width, height: hThickness)
        }
    }

    @objc func togglePanel(_ sender: AnyObject? = nil) {
        if panelVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        // Republish anything that piled up while hidden, before the first layout reads it.
        ClipboardStore.shared.publishingSuppressed = false
        previousApp = NSWorkspace.shared.frontmostApplication
        guard let panel else { return }
        // Lock in the display now (before makeKey can flip NSScreen.main) and publish the
        // matching card scale, so the bar and the cards are sized against the same screen.
        activeScreen = NSScreen.main ?? NSScreen.screens.first
        // Guarded: `panelScale` is @Published, and @Published emits even when assigned the same
        // value — an unconditional write here invalidated the whole panel on every single open,
        // although the scale only ever changes when the panel moves to a different-sized screen.
        let scale = PanelLayout.scale(for: activeScreen)
        if ClipboardStore.shared.panelScale != scale { ClipboardStore.shared.panelScale = scale }
        let target = panelFrame()
        let start  = offscreenFrame(for: target)

        panelVisible = true
        addMonitors()

        panel.setFrame(start, display: false, animate: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        // Route key events into the SwiftUI content so ⌘A / arrow keys / ⏎ work without first
        // clicking a card. Guarded: establishing first responder on the hosting view measured
        // 16–20ms, and it survives an orderOut, so after the warm-up this is a no-op.
        // Route key events into the SwiftUI content right away so ⌘A / arrow keys / ⏎ work the
        // instant the panel appears, without first clicking a card to establish first responder.
        //
        // This costs 16-20ms of layout and is the single biggest item on the open path, but it
        // has to stay here. Skipping it when the first responder is already somewhere inside the
        // content view does make the call free — and silently breaks arrow-key navigation,
        // because the responder it finds is not the one that forwards those keys. Deferring it
        // to just after the slide starts instead steals frames from the slide (measured 9-11
        // frames instead of 12-14).
        panel.makeFirstResponder(panel.contentView)
        NotificationCenter.default.post(name: .panelDidOpen, object: nil)

        // Start the slide on the NEXT runloop tick so the off-screen `start` frame is committed
        // and painted first — otherwise the very first open can begin mid-way (from the middle).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelVisible, self.panel != nil else { return }
            self.slidePanel(from: start, to: target, duration: 0.11, easeOut: true)
            // Housekeeping that nothing on the first frame depends on. Running it here keeps it
            // out of the window between the hotkey and the panel starting to move.
            ClipboardStore.shared.targetAppName = self.previousApp?.localizedName
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
            // Expiry used to be enforced at the top of showPanel, where a prune that actually
            // removed something re-laid the panel out before it could start moving. Off-screen
            // is the right moment for it.
            ClipboardStore.shared.pruneExpired()
            // Nothing is watching the panel now, so stop paying SwiftUI for its updates.
            // The Settings window observes the same store, so only go quiet when it is closed.
            if self?.settingsWindow?.isVisible != true {
                ClipboardStore.shared.publishingSuppressed = true
            }
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
        // The panel no longer touches the screen edge, so sliding it by its own thickness
        // would leave the edge gap's worth of it on screen — clear the gap and the shadow too.
        let slack = PanelLayout.screenInset + 40
        var f = frame
        switch pos {
        case "top":   f.origin.y = frame.maxY + slack
        case "left":  f.origin.x = frame.minX - frame.width - slack
        case "right": f.origin.x = frame.maxX + slack
        default:      f.origin.y = frame.minY - frame.height - slack
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
            // ⌘1…⌘9 paste the card carrying that number, ⌘⇧1…⌘⇧9 paste it as plain text.
            //
            // Handled here rather than with hidden SwiftUI Buttons carrying `.keyboardShortcut`:
            // the eighteen of those cost ~4ms of the panel's first-responder setup and ~7ms of
            // the whole open path, measured, because establishing first responder resolves every
            // registered key equivalent.
            if event.modifierFlags.contains(.command),
               let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
               (1...9).contains(digit) {
                NotificationCenter.default.post(
                    name: .pasteNumberedItem,
                    object: nil,
                    userInfo: ["number": digit,
                               "plainText": event.modifierFlags.contains(.shift)]
                )
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
        // The Settings window shows live history counts, so it needs the store publishing.
        ClipboardStore.shared.publishingSuppressed = false
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
    /// Measured off Paste's own panel on a 2x display: its cards are 464x464 device
    /// pixels, i.e. a 232pt square.
    static let cardBaseHeight: CGFloat = 232
    static let cardBaseWidth: CGFloat = 232
    /// Gap between neighbouring cards. Paste uses 24pt; this is deliberately tighter.
    static let cardSpacing: CGFloat = 18
    /// Height of a card's coloured header bar, measured off Paste (96 device pixels).
    static let cardHeaderHeight: CGFloat = 48
    /// Fixed chrome around the horizontal card row (toolbar + divider + list padding).
    /// Paste leaves 68pt above the card row and 24pt below it; `listTopPadding` below
    /// makes up the difference between 68 and the toolbar's own height.
    static let horizontalChrome: CGFloat = 92
    /// Padding between the divider under the toolbar and the top of the cards.
    static let listTopPadding: CGFloat = 10
    /// Padding between the bottom of the cards and the bottom edge of the panel.
    static let listBottomPadding: CGFloat = 24
    /// Fixed chrome around the vertical card column (horizontal list padding + slack).
    static let verticalChrome: CGFloat = 70
    /// Screen height (points) at/above which the full-size design is used.
    static let referenceScreenHeight: CGFloat = 1360
    static let minScale: CGFloat = 0.8
    /// Gap between the panel and the edges of the screen's visible frame.
    static let screenInset: CGFloat = 8
    /// Corner radius of the floating panel (window mask and SwiftUI clip must agree).
    static let cornerRadius: CGFloat = 20

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
