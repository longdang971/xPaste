import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// periphery:ignore:parameters nextHandler,event,userData
// The signature is Carbon's `EventHandlerUPP`, not ours: every parameter is required for the
// function to be installable, and this handler needs none of them.
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
    static let dragOutOfPanel       = Notification.Name("com.user.xPaste.dragOutOfPanel")
    static let panelDragBegan       = Notification.Name("com.user.xPaste.panelDragBegan")
    static let panelDragCancelled   = Notification.Name("com.user.xPaste.panelDragCancelled")
    /// Test hook: stands in for a drag that ended at a screen point. Only ever posted by the
    /// env-gated harness, because a synthetic mouse release cannot end a real dragging session —
    /// see the spec for what the spike found.
    static let simulateDragEnd      = Notification.Name("com.user.xPaste.simulateDragEnd")
    static let hotkeyChanged        = Notification.Name("com.user.xPaste.hotkeyChanged")
    static let pasteNumberedItem    = Notification.Name("com.user.xPaste.pasteNumberedItem")
    /// Save one named item to disk. Carries `itemID`.
    static let saveItemToFile       = Notification.Name("com.user.xPaste.saveItemToFile")
    /// ⌘S. Only the panel knows what is selected, so it turns this into a `saveItemToFile`.
    static let saveSelectedItem     = Notification.Name("com.user.xPaste.saveSelectedItem")
    /// Space. Same division of labour as ⌘S: the key monitor sees the press, the panel knows
    /// which card it is about.
    static let togglePreviewSelected = Notification.Name("com.user.xPaste.togglePreviewSelected")
    /// ⌘R renames the selected card, ⌘E opens it in the editor, ⌘O opens a link in the browser.
    /// Each arrives from the key monitor, and the panel decides whether the selected card is the
    /// kind the action applies to.
    static let renameSelectedItem   = Notification.Name("com.user.xPaste.renameSelectedItem")
    static let editSelectedItem     = Notification.Name("com.user.xPaste.editSelectedItem")
    static let openSelectedItem     = Notification.Name("com.user.xPaste.openSelectedItem")
    static let openSettingsWindow   = Notification.Name("com.user.xPaste.openSettingsWindow")
    /// "Check for Updates…" in the panel's ⋯ menu.
    static let openUpdateWindow     = Notification.Name("com.user.xPaste.openUpdateWindow")
    /// Posted by the update window's own buttons, which have no window to close themselves —
    /// the window is an `NSWindow` the delegate owns, not a SwiftUI scene.
    static let closeUpdateWindow    = Notification.Name("com.user.xPaste.closeUpdateWindow")
    static let settingsWindowWillShow = Notification.Name("com.user.xPaste.settingsWindowWillShow")
    /// The Settings window has gone. Two things wait on it: the store goes back to coalescing its
    /// updates, and the Accessibility poll inside the window stops.
    static let settingsWindowDidClose = Notification.Name("com.user.xPaste.settingsWindowDidClose")
    static let menuBarIconChanged   = Notification.Name("com.user.xPaste.menuBarIconChanged")
    static let screenSharingVisibilityChanged = Notification.Name("com.user.xPaste.screenSharingVisibilityChanged")
}

private class ClipboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The view the bar is drawn in. The window is taller than the bar while the reveal runs, so
    /// anything reasoning about where the top of the panel is has to ask this, not the window.
    weak var barView: NSView?

    /// Where the current press started, while it could still turn into a drag out of the panel.
    private var pressOrigin: NSPoint?

    private func isOverCardList(_ locationInWindow: NSPoint) -> Bool {
        PanelClickRegion.isOverCardList(locationInWindow,
                                        barTop: barView?.frame.maxY ?? frame.height)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {

        case .leftMouseDown:
            if event.modifierFlags.contains(.command), isOverCardList(event.locationInWindow) {
                NotificationCenter.default.post(
                    name: .cmdClickInPanel,
                    object: nil,
                    userInfo: ["locationInWindow": event.locationInWindow]
                )
                return
            }
            if event.clickCount == 2, isOverCardList(event.locationInWindow) {
                NotificationCenter.default.post(
                    name: .doubleClickInPanel,
                    object: nil,
                    userInfo: ["locationInWindow": event.locationInWindow]
                )
                return
            }
            // A plain press might still become a drag out of the panel. A ⌘-press is
            // multi-selection and a double-click pastes, so neither of those is ever a drag — both
            // have already returned above.
            pressOrigin = event.locationInWindow
            let loc = event.locationInWindow
            if let hit = contentView?.hitTest(loc),
               !(hit is NSTextView),
               isOverCardList(loc) {
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

        case .leftMouseDragged:
            if let origin = pressOrigin,
               DragPaste.exceedsThreshold(from: origin, to: event.locationInWindow) {
                pressOrigin = nil
                // The card is found from where the press started, not from where the pointer is
                // now: by this point it has already left the card it began on.
                NotificationCenter.default.post(
                    name: .dragOutOfPanel,
                    object: nil,
                    userInfo: ["locationInWindow": origin, "event": event]
                )
                return
            }

        case .leftMouseUp:
            pressOrigin = nil

        default:
            break
        }
        super.sendEvent(event)
    }
}

/// The panel's content view, deliberately larger than the bar drawn inside it.
///
/// It exists so the window can stay still while the bar slides, and it must never claim a click of
/// its own: the area beside the bar is the slide's runway, and at rest it can sit over the Dock.
private final class PanelContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var panel: ClipboardPanel?
    private var panelVisible = false
    private var hotKeyRef: EventHotKeyRef?
    private var settingsWindow: NSWindow?
    private var updateWindow: NSWindow?
    /// Outlives the window on purpose: closing the window mid-download must not abandon the
    /// download, and a build already staged has to still be there when the window is reopened.
    private let updateController = UpdateController()
    private let updateCheckPresenter = UpdateCheckPresenter()
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var alertIsPresented = false
    /// The screen the panel was last shown on. Captured once per show so the bar's frame, the
    /// runway it slides along, and the card scale are all computed against the same display.
    private var activeScreen: NSScreen?
    /// Fires a short while after copies stop arriving, to lay the hidden panel out ahead of time.
    private var prewarmTimer: Timer?
    /// The SwiftUI content itself. Its frame never changes, so the reveal costs SwiftUI nothing.
    private var panelHost: NSView?
    /// The view the reveal animates: it carries the bar and slides along the runway inside a
    /// stationary window. See `slideGeometry(for:)`.
    private var panelSlider: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.register(defaults: [
            "showDuringScreenSharing": true,
            "ignoreConfidentialContent": true,
            "ignoreTransientContent": true,
            // Passwords.app and Keychain Access are excluded out of the box.
            "ignoredAppBundleIDs": ["com.apple.Passwords", "com.apple.keychainaccess"],
            "ocrEnabled": true,
            "multiPasteSeparator": "newline",
        ])
        AppearanceManager.applyStored()
        setupStatusItem()
        setupPanel()
        setupHotKey()
        ClipboardMonitor.shared.start()
        DragTempFile.clearLeftovers()
        warmPanel()
        // Index older screenshots for search. Deliberately late and paused whenever the panel is
        // open, so it can never compete with the hotkey path for the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { OCRService.startBackfill() }

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
            self, selector: #selector(handlePanelDragBegan),
            name: .panelDragBegan, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handlePanelDragCancelled),
            name: .panelDragCancelled, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAlertHidden),
            name: .clipboardAlertHidden, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSaveItemToFile),
            name: .saveItemToFile, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleHidePanelForEditing),
            name: .hidePanelForEditing, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettingsWindow, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openUpdateWindow),
            name: .openUpdateWindow, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(closeUpdateWindow),
            name: .closeUpdateWindow, object: nil
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
            self?.startFirstLaunchFlow()
        }

        ClipboardStore.shared.onPendingChange = { [weak self] in self?.schedulePrewarm() }

        startPerfHarnessIfRequested()
    }

    /// Lays the hidden panel out ahead of the next hotkey press.
    ///
    /// While the panel is hidden the store coalesces updates instead of publishing them, so a copy
    /// costs nothing. The bill comes due on the next open: `orderFrontRegardless` flushes the whole
    /// pending SwiftUI transaction before the window may become visible, measured at 31–38ms with
    /// only three new items — all of it spent with the user already waiting for the panel to move.
    ///
    /// Paying it here instead costs the same work at a moment when nothing is on screen and no
    /// animation is running. Debounced, so a burst of copies is settled once rather than per item.
    private func schedulePrewarm() {
        prewarmTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.prewarmPanelLayout()
        }
        prewarmTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func prewarmPanelLayout() {
        prewarmTimer = nil
        // Only worth doing while hidden; while visible the store is already publishing live.
        guard !panelVisible, ClipboardStore.shared.publishingSuppressed,
              ClipboardStore.shared.hasPendingChange, let panel else { return }
        PerfLog.begin("prewarm")
        ClipboardStore.shared.publishingSuppressed = false
        PerfLog.mark("publish")
        // Drive the layout now rather than leaving it queued for the next order-in.
        //
        // Only the layout: also forcing a real off-screen render here (ordering the window in at
        // alpha 0, the way `warmPanel` does) was measured and bought nothing — the work the open
        // still pays comes from the panel becoming key, not from a missing display list.
        panel.contentView?.layoutSubtreeIfNeeded()
        PerfLog.mark("layoutSubtreeIfNeeded")
        // Back to coalescing, so the copies that arrive after this one stay free.
        if settingsWindow?.isVisible != true {
            ClipboardStore.shared.publishingSuppressed = true
        }
        PerfLog.end()
    }

    /// Opens and closes the panel on a timer so the open path can be measured without a human on
    /// the hotkey. Only ever runs under `XPASTE_PERF=1 XPASTE_AUTOOPEN=<n>`; `XPASTE_DWELL=<secs>`
    /// holds each open for longer, which is what makes synthetic clicks into the panel possible.
    private func startPerfHarnessIfRequested() {
        guard PerfLog.enabled,
              let rounds = ProcessInfo.processInfo.environment["XPASTE_AUTOOPEN"].flatMap({ Int($0) }),
              rounds > 0
        else { return }
        var done = 0
        var synthetic: [UUID] = []
        func cycle() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                PerfLog.note("--- round \(done + 1) ---")
                // Simulate copies made while the panel was hidden — the store coalesces them and
                // republishes on open, which is the realistic path, not the idle reopen. The gap
                // before opening matters: nobody presses the hotkey in the same instant they copy.
                if let copies = ProcessInfo.processInfo.environment["XPASTE_COPIES"].flatMap({ Int($0) }) {
                    for i in 0..<copies {
                        let item = ClipboardItem(
                            type: .text, text: "harness item \(done)-\(i) " + String(repeating: "x", count: 200),
                            sourceAppBundleID: "com.apple.Terminal")
                        synthetic.append(item.id)
                        ClipboardStore.shared.add(item)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.showPanel()
                    // How long the panel is left open. Long enough to be clicked, when the point of
                    // the run is to check that clicks still land where they should.
                    let dwell = ProcessInfo.processInfo.environment["XPASTE_DWELL"]
                        .flatMap { Double($0) } ?? 1.0
                    // `XPASTE_DRAGEND=x,y[,shift]` stands in for a drag released at that screen
                    // point. The gesture itself cannot be synthesised — a CGEvent release does not
                    // end a dragging session — so this is how the paste-and-select tail of the
                    // pipeline gets verified by machine.
                    if let spec = ProcessInfo.processInfo.environment["XPASTE_DRAGEND"] {
                        let parts = spec.split(separator: ",").map(String.init)
                        if parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                PerfLog.note("simulating a drag ended at \(x),\(y)")
                                NotificationCenter.default.post(
                                    name: .simulateDragEnd, object: nil,
                                    userInfo: ["screenPoint": NSPoint(x: x, y: y),
                                               "shift": parts.count > 2 && parts[2] == "shift"]
                                )
                            }
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + dwell) {
                        self.hidePanel()
                        done += 1
                        if done < rounds { cycle() } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                // Never leave synthetic items behind in the real history.
                                ClipboardStore.shared.deleteItems(ids: Set(synthetic))
                                PerfLog.note("harness finished, removed \(synthetic.count) synthetic items")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                            }
                        }
                    }
                }
            }
        }
        cycle()
    }

    /// First launch shows Quick Start; the Accessibility prompt waits until it's dismissed so
    /// the user never faces two setup dialogs stacked on top of each other.
    private func startFirstLaunchFlow() {
        let defaults = UserDefaults.standard
        // Installs that already went through the older first-launch prompt are past setup —
        // don't greet them with Quick Start after an update.
        if defaults.bool(forKey: "didPromptAccessibility") {
            defaults.set(true, forKey: "didCompleteOnboarding")
        }
        guard !defaults.bool(forKey: "didCompleteOnboarding") else {
            promptAccessibilityOnFirstLaunchIfNeeded()
            return
        }
        showOnboardingWindow()
    }

    private func showOnboardingWindow() {
        if onboardingWindow == nil {
            let controller = NSHostingController(
                rootView: OnboardingView(onContinue: { [weak self] in
                    self?.onboardingWindow?.close()
                })
            )
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.title = "Quick Start"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(OnboardingView.windowSize)
            window.center()
            window.delegate = self
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow, closing === settingsWindow {
            // Publishing was switched on for this window and nothing switched it back.
            //
            // Every other path that stops it — hiding the panel, the prewarm — is guarded on the
            // Settings window not being visible, and none of them runs on the way out of Settings.
            // So after one visit the store went on publishing live: with the panel hidden and
            // nobody watching, every copy in the system paid a full SwiftUI layout of it, until
            // the next time the panel happened to be opened and closed.
            NotificationCenter.default.post(name: .settingsWindowDidClose, object: nil)
            if !panelVisible { ClipboardStore.shared.publishingSuppressed = true }
            return
        }
        guard let closing = notification.object as? NSWindow, closing === onboardingWindow else { return }
        onboardingWindow = nil
        UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
        // Closing with the red button counts as finishing setup, so the Accessibility prompt
        // follows either way — after the window is actually gone.
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
        guard UserDefaults.standard.bool(forKey: "clearOnLogout") else { return }
        ClipboardStore.shared.clearAll()
        // Erasing is queued too, and the machine is about to go. An erase that did not finish is
        // the one kind of unfinished work that matters here.
        ClipboardStore.shared.flushPendingWrites()
    }

    @objc private func handleWillSleep() {
        guard UserDefaults.standard.bool(forKey: "clearOnLogout") else { return }
        ClipboardStore.shared.clearAll()
        ClipboardStore.shared.flushPendingWrites()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardMonitor.shared.stop()
        // Saves are queued, not immediate. Quitting straight after a copy left most of it unwritten.
        ClipboardStore.shared.flushPendingWrites()
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    }

    // Re-opening the app from Finder/Launchpad/Dock while it's already running (an accessory app
    // won't launch a second instance) routes here instead. Show the panel so double-clicking the
    // app icon in /Applications behaves like the hotkey.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboardingWindow?.isVisible == true {
            onboardingWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
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

    // periphery:ignore:parameters sender
    // Target/action hands the button in; the event this needs comes from `NSApp.currentEvent`.
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
        self.panelHost = hostingView
        // The panel sizes itself from the screen, never from its content. Left at the default,
        // NSHostingView pushes SwiftUI's min/max size onto the window as size constraints, which
        // costs a full `sizeThatFits` pass over the whole tree on every layout — measured at 6%
        // of the main thread's work on the open path, for a number nothing reads.
        hostingView.sizingOptions = []
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

        // The bar is not the window's whole content any more: it rides on a slider inside a
        // container that also covers the runway the bar travels along. That is what lets the reveal
        // be a Core Animation translate of the slider rather than a per-frame move of the window —
        // see `slideGeometry(for:)` for why moving the window is what made the reveal stutter.
        let slider = NSView(frame: NSRect(origin: .zero, size: panelFrame().size))
        slider.wantsLayer = true
        slider.addSubview(hostingView)
        hostingView.frame = slider.bounds
        hostingView.autoresizingMask = [.width, .height]
        self.panelSlider = slider

        let container = PanelContainerView(frame: NSRect(origin: .zero, size: panelFrame().size))
        container.wantsLayer = true
        container.addSubview(slider)
        p.contentView = container
        p.barView = slider
        // Without this, showing the panel sends AppKit hunting for a first responder itself
        // (`_selectFirstKeyView`), and what it finds is the search field — which lives in the
        // toolbar at opacity 0 whether the search box is open or not. It then calls `selectText:`
        // on it, spinning up a field editor and a SwiftUI focus update; the `makeFirstResponder`
        // in showPanel immediately tears that same field editor back down. Profiling put the two
        // halves of that round trip at 13% of all main-thread work on the open path.
        p.initialFirstResponder = hostingView
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
            self.renderPanelOffScreen(panel)
            if self.settingsWindow?.isVisible != true {
                ClipboardStore.shared.publishingSuppressed = true
            }
        }
    }

    /// Forces a real render of the panel's SwiftUI tree without ever showing it.
    ///
    /// Laying the hosting view out is not enough on its own: with the window ordered out, SwiftUI
    /// stops short of building a display list, and the render is billed to the next open instead
    /// (12–15ms, measured). Ordering the window in — off-screen and fully transparent — makes that
    /// render happen here. Alpha 0 for the duration because ordering it in at an off-screen frame
    /// still flashed it on screen for a frame.
    private func renderPanelOffScreen(_ panel: NSPanel) {
        panel.alphaValue = 0
        // Parked in exactly the state an open expects to find: stretched over the bar and its
        // runway, with the bar at the far end of it. Every later open then finds the window already
        // the right size and only has to order it in — see `stretchPanel`.
        let geo = slideGeometry(for: panelFrame())
        stretchPanel(geo)
        parkBarOffScreen(geo)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        // Establish first responder here too: NSWindow remembers it across orderOut, so the
        // per-open call finds it already set and costs nothing.
        panel.makeFirstResponder(panelHost)
        panel.orderOut(nil)
        panel.alphaValue = 1
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

    /// The panel stays out of the way until first-launch setup is finished — otherwise the
    /// hotkey the user is in the middle of recording would slide it over Quick Start.
    private var onboardingIsPresented: Bool { onboardingWindow?.isVisible == true }

    @objc func togglePanel(_ sender: AnyObject? = nil) {
        if panelVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard !onboardingIsPresented else {
            // Bring the setup window back to the front instead, so the ignored hotkey still
            // points at what the user has to deal with first.
            onboardingWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        PerfLog.begin("open")
        // Republish anything that piled up while hidden, before the first layout reads it.
        ClipboardStore.shared.publishingSuppressed = false
        PerfLog.mark("publishingSuppressed=false")
        previousApp = NSWorkspace.shared.frontmostApplication
        PerfLog.mark("frontmostApplication")
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
        let geo = slideGeometry(for: target)
        PerfLog.mark("screen+frames")

        panelVisible = true
        addMonitors()
        PerfLog.mark("addMonitors")

        // The window is placed once, stretched over the bar and its runway, and does not move
        // again for the whole reveal. The bar is parked at the far end of that runway, so the
        // window can be ordered in with nothing of it on screen yet.
        stretchPanel(geo)
        parkBarOffScreen(geo)
        PerfLog.mark("setFrame")
        panel.orderFrontRegardless()
        PerfLog.mark("orderFrontRegardless")
        // Costs ~13ms of SwiftUI re-render on its own: becoming key flips the control-active
        // state the whole tree reads, so every view is re-evaluated. Measured with and without.
        // It has to stay and it has to stay here — the panel needs the keyboard the moment it
        // appears, and deferring it past the slide would only move the same stall onto a
        // moving panel.
        panel.makeKey()
        PerfLog.mark("makeKey")
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
        panel.makeFirstResponder(panelHost)
        PerfLog.mark("makeFirstResponder")
        NotificationCenter.default.post(name: .panelDidOpen, object: nil)
        PerfLog.mark("post panelDidOpen")

        // Hand the reveal over on the NEXT runloop tick, so the window's placement and the bar's
        // parked position are committed and painted first — otherwise the very first open can
        // begin mid-way.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelVisible, self.panel != nil else { return }
            // Everything between the previous mark and this one is work the main thread did on
            // its own after showPanel returned: SwiftUI's layout/render pass, chiefly.
            PerfLog.mark("runloop turn (SwiftUI layout+render)")
            PerfLog.end()
            self.revealPanel(geo, hiding: false, duration: Self.revealDuration) { [weak self] in
                // Back to exactly the bar's own frame the moment it has arrived, so the runway
                // stops covering anything — see `PanelContainerView`.
                self?.collapsePanelToBar(target)
            }
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
        guard panel != nil else { return }

        // Give the runway back before animating onto it. The bar keeps its place on screen — only
        // the window around it grows — so this is invisible.
        let geo = slideGeometry(for: panelFrame())
        stretchPanel(geo)
        // On the NEXT runloop turn, for the same reason the reveal waits one: Core Animation takes an
        // animation's starting point from what is currently *on screen*, and the staging above has
        // not been committed to the render server yet. Animating in the same turn interpolated from
        // the bar's old position to itself — a hide that ran for its full 100ms and moved nothing, so
        // the panel simply vanished when the window was ordered out. Measured on the presentation
        // layer; the model was right the whole time, which is why the idle-watch timing looked fine.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.panelVisible else { return }
            self.animateHide(geo)
        }
    }

    private func animateHide(_ geo: PanelLayout.PanelSlideGeometry) {
        revealPanel(geo, hiding: true, duration: Self.hideDuration) { [weak self] in
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

    /// How long the bar takes to arrive, and to leave.
    ///
    /// Measured against Paste on the same 5K 60Hz display, because "smoother" turned out not to be
    /// about dropped frames at all. Sampling this app's own presentation layer every display tick
    /// found the main thread free and **no frame missed** — the reveal simply had only six frames
    /// to cross 380pt, so each one moved 45–101pt and the eye read it as a snap rather than a
    /// glide. Paste's own reveal, measured off a 60fps screen recording, runs eight to nine frames
    /// (~133ms) with its per-frame change decaying 63 → 44 → 28 → 18 → 13 → 9 → 6 → 3.5.
    ///
    /// 0.15 and 0.13 buy nine and eight frames at 60Hz, which is the difference that was actually
    /// being seen. Nothing about the machinery changed: the reveal is still one Core Animation on
    /// one view inside a window that never moves.
    static let revealDuration: TimeInterval = 0.15
    static let hideDuration: TimeInterval = 0.13

    private func slideGeometry(for target: NSRect) -> PanelLayout.PanelSlideGeometry {
        let pos = UserDefaults.standard.string(forKey: "panelPosition") ?? "bottom"
        return PanelLayout.slideGeometry(for: target, position: pos)
    }

    /// Gives the window the runway back, leaving the bar exactly where it appears on screen.
    ///
    /// Nothing happens when the window is already stretched, which is the common case: a hide
    /// leaves it that way, so a later open only has to park the bar. That matters twice over. The
    /// stretched surface is over twice the bar's and ordering it in is measurably dearer, so the
    /// open path pays for it once at launch rather than on every hotkey press; and a reveal
    /// interrupted mid-flight by a hide must not have its bar snapped anywhere, which is exactly
    /// what re-staging it would do.
    private func stretchPanel(_ geo: PanelLayout.PanelSlideGeometry) {
        guard let panel, let slider = panelSlider, panel.frame != geo.windowFrame else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.setFrame(geo.windowFrame, display: false, animate: false)
        // The window's origin moved, so the bar's offset inside it has to move with it or the bar
        // would jump on screen by the length of the runway.
        slider.frame = geo.barFrame
        NSAnimationContext.endGrouping()
    }

    /// Puts the bar at the far end of the runway, where none of it is on screen. Only ever called
    /// with the panel hidden, so there is nothing for the jump to be visible in.
    private func parkBarOffScreen(_ geo: PanelLayout.PanelSlideGeometry) {
        guard let slider = panelSlider else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        slider.frame = geo.displacedBarFrame
        NSAnimationContext.endGrouping()
    }

    /// Shrinks the window back onto the bar once the bar has arrived, so the runway stops covering
    /// what is behind it — at the bottom of the screen that includes the Dock, and a transparent
    /// window over the Dock still swallows the click.
    ///
    /// The bar does not move on screen: the window's origin and the bar's offset inside it change
    /// by the same amount, in one unanimated grouping.
    private func collapsePanelToBar(_ target: NSRect) {
        guard let panel, let slider = panelSlider, panelVisible else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.setFrame(target, display: false, animate: false)
        slider.frame = NSRect(origin: .zero, size: target.size)
        NSAnimationContext.endGrouping()
    }

    /// Slides the bar along the runway — the reveal itself.
    ///
    /// One Core Animation on one view: the render server interpolates it at the display's own
    /// refresh rate and the main thread does nothing at all until it finishes. That is the whole
    /// point, so nothing here may touch the window's frame.
    private func revealPanel(_ geo: PanelLayout.PanelSlideGeometry, hiding: Bool, duration: TimeInterval,
                             completion: (() -> Void)?) {
        guard let slider = panelSlider else { completion?(); return }
        let displaced = geo.displacedBarFrame
        PerfLog.beginIdleWatch()
        FrameProbe.begin(hiding ? "hide" : "reveal", view: slider)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            // Matches the old hand-rolled easing: out on the way in, in on the way out.
            context.timingFunction = CAMediaTimingFunction(name: hiding ? .easeIn : .easeOut)
            context.allowsImplicitAnimation = true
            slider.animator().setFrameOrigin(hiding ? displaced.origin : geo.barFrame.origin)
        } completionHandler: { [weak self] in
            PerfLog.endIdleWatch(hiding ? "hide" : "reveal")
            FrameProbe.end()
            self?.revealFinished(hiding: hiding, completion: completion)
        }
    }

    /// AppKit calls an animation's completion handler even when the animation was replaced by a
    /// newer one, so a reveal that was interrupted by a hide (or the other way round) must not run
    /// the finishing work of the animation that no longer applies.
    private func revealFinished(hiding: Bool, completion: (() -> Void)?) {
        guard hiding != panelVisible else { return }
        completion?()
    }

    /// Each monitor guarded on its own.
    ///
    /// One `guard mouseMonitor == nil` used to cover both. `addGlobalMonitorForEvents` returns nil
    /// when the system refuses the monitor, and a nil mouse monitor then left the guard open — so
    /// every subsequent open installed another key monitor on top of the last. Duplicates are not
    /// merely a leak here: each one posts `pasteNumberedItem`, so ⌘1 would paste the same card
    /// once per open the panel had ever had.
    private func addMonitors() {
        if mouseMonitor == nil { mouseMonitor = makeMouseMonitor() }
        if keyMonitor == nil { keyMonitor = makeKeyMonitor() }
    }

    private func makeMouseMonitor() -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if let button = self.statusItem?.button, let win = button.window {
                if win.convertToScreen(button.frame).contains(NSEvent.mouseLocation) { return }
            }
            // Not while an editor, a rename or a confirmation is up — the same flag Escape already
            // stands down for.
            //
            // Clicking into another application used to take the panel away underneath an open
            // editor. That left the editor's popover orphaned: with its parent window gone it is no
            // longer key, so its selection greys out, its text view is no longer first responder,
            // clicks stop moving the caret and the toolbar's commands land on nothing — and a
            // half-finished edit goes with it. Measured directly: ordering the panel out flips the
            // popover window's `isKeyWindow` to false and moves first responder off the text view.
            guard !self.alertIsPresented else { return }
            self.hidePanel()
        }
    }

    private func makeKeyMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                if self.alertIsPresented { return event }
                self.hidePanel()
                return nil
            }
            // While an alert is up — or a card's name is being edited, which borrows the same
            // flag — the panel's own shortcuts must stay out of the way: ⌘1 belongs to the text
            // field, not to "paste card 1".
            if self.alertIsPresented { return event }
            // Space opens the selected card's preview and puts it away again — the panel's one
            // unmodified shortcut, and the one that has to survive being leaned on.
            //
            // It used to be three separate things: a hidden `.keyboardShortcut(.space)` Button in
            // the panel to open, another inside the popover to close, and — because a text
            // preview's own text view swallows a plain space before either could resolve — a key
            // monitor living on the popover's content view. Both halves dropped presses. That
            // monitor swallowed every space for as long as it was installed, and SwiftUI only
            // tears the content view down once the closing animation has finished, so spaces
            // arriving during the close were eaten with nothing left to close. Reopening then
            // needed the panel's key equivalent to resolve while key window and first responder
            // were still on their way back from the popover, and in that gap it did not. Hence
            // one monitor, one flip per press, and no window standing in between.
            if PreviewSpaceKey.togglesPreview(keyCode: event.keyCode,
                                              modifiers: event.modifierFlags,
                                              firstResponder: event.window?.firstResponder,
                                              inPanel: event.window === self.panel) {
                NotificationCenter.default.post(name: .togglePreviewSelected, object: nil)
                return nil
            }
            // Exactly the modifiers named, nothing extra: ⌥⌘S and ⌃⌘S belong to whatever the user
            // has bound them to, not to xPaste.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            if mods == .command, event.charactersIgnoringModifiers == "," {
                self.hidePanel()
                self.openSettings()
                return nil
            }
            // ⌘S saves the selected card. Handled here, beside ⌘, and the ⌘-digits, rather than as
            // another hidden SwiftUI Button — establishing first responder resolves every
            // registered key equivalent, which is why eighteen of those were moved out of the
            // panel. Only the panel knows what is selected, so it turns this into a save.
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
                NotificationCenter.default.post(name: .saveSelectedItem, object: nil)
                return nil
            }
            // ⌘R rename, ⌘E edit, ⌘O open a link — the card commands that had none. Here beside
            // ⌘S rather than as three more hidden SwiftUI Buttons for the reason given above, and
            // because two of the three (rename, edit) put a text field on screen: a key equivalent
            // that only resolves once first responder has settled is exactly the wrong mechanism
            // for a command whose job is to move first responder somewhere else.
            if mods == .command,
               let key = event.charactersIgnoringModifiers?.lowercased(),
               let command = CardCommandKey.command(for: key) {
                NotificationCenter.default.post(name: command, object: nil)
                return nil
            }
            // ⌘1…⌘9 paste the card carrying that number, ⌘⇧1…⌘⇧9 paste it as plain text.
            //
            // Handled here rather than with hidden SwiftUI Buttons carrying `.keyboardShortcut`:
            // the eighteen of those cost ~4ms of the panel's first-responder setup and ~7ms of
            // the whole open path, measured, because establishing first responder resolves every
            // registered key equivalent.
            if mods == .command || mods == [.command, .shift],
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

    /// The panel gets out of the way for the length of a drag: it covers the strip of screen the
    /// item may be headed for, and leaving it up afterwards means reaching for Escape every time.
    /// Verified safe — a dragging session survives its source window being ordered out.
    @objc private func handlePanelDragBegan() { hidePanel() }

    /// Escape during a drag puts everything back, the panel included. Nothing has been written to the
    /// pasteboard at this point: that only happens once a drag has ended in a paste.
    @objc private func handlePanelDragCancelled() {
        guard !panelVisible else { return }
        showPanel()
    }

    /// The editor is a window of its own now, and it opens with the bar out of the way — see
    /// `EditWindowPresenter`.
    @objc private func handleHidePanelForEditing() { if panelVisible { hidePanel() } }

    @objc private func handleAlertShown()  { alertIsPresented = true  }
    @objc private func handleAlertHidden() { alertIsPresented = false }

    @objc private func handleToggleClipboard() {
        togglePanel()
    }

    /// Pastes into the target application, optionally one the caller names.
    ///
    /// A keyboard paste means "the app the panel was opened in front of". A drag out of the panel
    /// names the app it was released over instead, and asks for the pasted text to be left selected —
    /// see `DragPaste`. Both arrive through the same notification so there is only ever one paste
    /// path to keep working.
    @objc private func handlePasteItem(_ note: Notification) {
        guard AccessibilityPermission.isTrusted else {
            hidePanel()
            AccessibilityPermission.requestSystemPrompt()
            AccessibilityPermission.openSystemSettings()
            return
        }
        let named = (note.userInfo?["targetPID"] as? pid_t)
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        let target = named ?? previousApp
        let targetPID = target?.processIdentifier ?? 0
        // Only a drag asks for this: it is what leaves the pasted text selected, ready to be typed
        // straight over.
        let selectLength = note.userInfo?["selectLength"] as? Int
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
            guard let selectLength, targetPID > 0 else { return }
            // Long enough for the target to have processed the keystroke and moved its caret; the
            // selection is read back from wherever that ended up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                AXTextSelection.selectPastedText(pid: targetPID, length: selectLength)
            }
        }
    }

    // MARK: - Saving an item to a file

    /// Writes one item to disk through a Save dialog.
    ///
    /// Run from here rather than from `ContentView` because the panel is a `nonactivatingPanel` that
    /// never becomes key or main, and the app runs as an accessory: a dialog needs the app activated
    /// first. That is the same sequence `openSettings` performs. Hiding the panel first also settles
    /// the global mouse monitor, which would otherwise treat the first click into the dialog as a
    /// click outside the panel.
    @objc private func handleSaveItemToFile(_ note: Notification) {
        guard let id = note.userInfo?["itemID"] as? UUID,
              let stored = ClipboardStore.shared.items.first(where: { $0.id == id }),
              SaveFormat.canSave(stored.type)
        else { return }
        // Hydrated for the same reason the pixels are read below: `SaveFormat` knows nothing about
        // the store, and a file saved from the prefix a card shows would be a truncated file with
        // nothing to say it was.
        let item = ClipboardStore.shared.hydrated(stored)

        // An image's pixels may live on disk rather than on the item, and `SaveFormat` deliberately
        // knows nothing about the store — so they are read here and handed in.
        // The original. Someone asking to save a picture is asking for that picture, and saving a
        // re-encode while the bytes that were copied sit right beside it is a loss with nothing on
        // screen to say it happened.
        let imageBytes: Data? = item.type == .image
            ? ClipboardStore.shared.originalImageBytes(for: item)
            : nil
        let suggestion = SaveFormat.suggest(for: item, imageBytes: imageBytes)

        hidePanel()
        // On the next runloop turn: the hide is staged in this one, and running a modal dialog
        // before it is committed leaves the bar frozen on screen behind the dialog.
        DispatchQueue.main.async { [weak self] in
            self?.presentSavePanel(for: suggestion)
        }
    }

    private func presentSavePanel(for suggestion: SaveFormat.Suggestion) {
        NSApp.activate(ignoringOtherApps: true)

        let dialog = NSSavePanel()
        // Just the extension — no name guessed from the content. The caret is put in front of the
        // dot a few lines below, so the field is ready to be typed into.
        dialog.nameFieldStringValue = suggestion.dialogFileName
        dialog.canCreateDirectories = true
        dialog.isExtensionHidden = false

        // Anything may be typed over the suggestion. For text the extension is only a label —
        // the bytes are the same UTF-8 either way — and naming a content type here is what produced
        // `.json.json`: the panel read the leading dot as a name and appended the extension again.
        dialog.allowsOtherFileTypes = true

        // Collapse the selection to the start once the panel is up, so the extension is not sitting
        // highlighted and about to be typed over. Scheduled rather than run here because the panel
        // is not on screen until `runModal` below; `SaveNameCaret` explains the rest.
        let caretNudge = Self.startCaretNudge(for: dialog, suggested: suggestion.dialogFileName)

        let choice = dialog.runModal()
        // The dialog is gone, so a press from here on would land on whatever is in front now.
        caretNudge.invalidate()
        defer { returnFocusToPreviousApp() }
        guard choice == .OK, let chosen = dialog.url else { return }
        let target = SaveFormat.ensuringName(chosen)

        // A Link saves the page itself, which has to be fetched — so the write happens after an
        // await rather than inline. Every other item resolves to itself and lands immediately;
        // one path for both keeps the error handling in a single place.
        Task { @MainActor in
            do {
                try ItemFileWriter.write(try await ItemFileWriter.resolving(suggestion), to: target)
            } catch {
                presentSaveFailure(error)
            }
        }
    }

    /// Drives `SaveNameCaret` for as long as it asks to be driven, and hands back the timer so the
    /// caller can stop it the moment `runModal` returns.
    ///
    /// A run-loop timer rather than a queued block, and registered in the modal panel's mode: the
    /// dialog is run from inside a main-queue block, so anything queued behind it waits for the
    /// dialog to close — see `SaveNameCaret`. `.default` is in the list too, so the timer is not
    /// left dead if the panel ever stops being modal.
    @discardableResult
    private static func startCaretNudge(for dialog: NSSavePanel, suggested: String) -> Timer {
        var presses = 0
        let timer = Timer(timeInterval: SaveNameCaret.tickInterval, repeats: true) { timer in
            let step = SaveNameCaret.step(presses: presses,
                                          currentName: dialog.nameFieldStringValue,
                                          suggestedName: suggested)
            guard step == .press else { timer.invalidate(); return }
            pressLeftArrow()
            presses += 1
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
        return timer
    }

    /// One left-arrow press, to the front-most window.
    private static func pressLeftArrow() {
        let source = CGEventSource(stateID: .hidSystemState)
        let left: CGKeyCode = 0x7B
        CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: left, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    /// Hands the keyboard back to whatever the panel was opened in front of.
    ///
    /// Activating xPaste for the dialog is unavoidable, but xPaste is an accessory with no window
    /// left once the dialog closes — so without this the user is dropped somewhere with no focus at
    /// all and has to click back into what they were doing. The paste path already does the same.
    private func returnFocusToPreviousApp() {
        previousApp?.activate(options: [])
    }

    private func presentSaveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t save the file"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            window.delegate = self
            settingsWindow = window
        }
        // The Settings window shows live history counts, so it needs the store publishing.
        ClipboardStore.shared.publishingSuppressed = false
        // The window and its hosting controller are kept between visits so it reopens where the
        // user left it on screen — but its selected tab is SwiftUI @State and survives with it,
        // so a visit that ended on Privacy reopened on Privacy. Tell the view a new visit is
        // starting; resetting here rather than rebuilding the window keeps the position.
        NotificationCenter.default.post(name: .settingsWindowWillShow, object: nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// "Check for Updates…": check first, then decide what is worth putting on screen.
    ///
    /// The big window — icon, release notes, progress — opens only when there is genuinely a new
    /// version to talk about, or when a run is already under way. Everything else (checking, up to
    /// date, the check failed) is a small panel with an OK button, because a scrollable "What's
    /// New" box is a lot of window to say "nothing has changed".
    @objc private func openUpdateWindow() {
        if panelVisible { hidePanel() }
        Task { @MainActor in await runUpdateCheck() }
    }

    @MainActor private func runUpdateCheck() async {
        // A run in flight belongs in the big window: the progress bar and the install button exist
        // nowhere else, and `check()` refuses to start on top of one anyway.
        switch updateController.state {
        case .downloading, .preparing, .readyToInstall, .installing, .available:
            presentUpdateWindow()
            return
        case .idle, .checking, .upToDate, .error:
            break
        }

        updateCheckPresenter.show(.checking)
        await updateController.check()
        switch updateController.state {
        case .available, .readyToInstall:
            updateCheckPresenter.dismiss()
            presentUpdateWindow()
        case let .upToDate(current):
            updateCheckPresenter.show(.upToDate(version: current))
        case let .error(message):
            updateCheckPresenter.show(.failed(message: message))
        case .idle, .checking, .downloading, .preparing, .installing:
            // `check()` never settles on any of these; if it somehow did, the big window is the
            // safest place for the user to see what is going on.
            updateCheckPresenter.dismiss()
            presentUpdateWindow()
        }
    }

    /// Opens the update window, on the same terms as Settings: the panel goes away first, and the
    /// app is activated, because an accessory app's window opens behind everything otherwise.
    ///
    /// The window is kept between visits so it reopens where it was left, and because a download in
    /// progress is showing inside it — rebuilding it each time would restart the view mid-transfer.
    private func presentUpdateWindow() {
        if panelVisible { hidePanel() }
        if updateWindow == nil {
            let controller = NSHostingController(
                rootView: UpdateWindowView(controller: updateController)
            )
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.title = "Software Update"
            window.styleMask = [.titled, .closable]
            // Tall enough for the whole layout at once: 64pt of header, the notes box at its
            // 200pt minimum, and the download row underneath. At 560×300 the content did not fit,
            // so the bottom padding was squeezed out and the byte counters ended up flush against
            // the window's bottom edge while the release notes were clipped.
            window.setContentSize(NSSize(width: 640, height: 470))
            window.center()
            updateWindow = window
        }
        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The window's own buttons close it through here, since the view holds no reference to it.
    @objc private func closeUpdateWindow() {
        updateWindow?.performClose(nil)
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
        let keyCode = UserDefaults.standard.object(forKey: HotkeyDefaults.keyCodeKey) as? Int
            ?? HotkeyDefaults.keyCode
        let modifiers = UserDefaults.standard.object(forKey: HotkeyDefaults.modifiersKey) as? Int
            ?? HotkeyDefaults.modifiers
        let hotKeyID = EventHotKeyID(signature: 0x434C4D47, id: 1)
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(0),
            &hotKeyRef
        )
        guard status != noErr else { return }

        // The combination was refused. Left as it was, the app has no shortcut at all — and with
        // the menu bar icon hidden there is then no way to open the panel, which is precisely the
        // state `HotkeyRecorderButton.reset` exists to avoid. Fall back to the built-in one and put
        // that on record, so Settings shows what actually works rather than what was asked for.
        //
        // This catches a combination the system refuses outright. It cannot catch one that
        // registers and is then swallowed by an existing system shortcut — Carbon reports success
        // for those, and there is no API that says otherwise.
        hotKeyRef = nil
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: HotkeyDefaults.keyCodeKey) != nil else { return }
        defaults.removeObject(forKey: HotkeyDefaults.keyCodeKey)
        defaults.removeObject(forKey: HotkeyDefaults.modifiersKey)
        defaults.set(HotkeyDefaults.display, forKey: HotkeyDefaults.displayKey)
        registerHotKeyFromDefaults()
    }
}

// MARK: - Adaptive panel sizing

/// Keeps the panel (and its cards) at a pleasant proportion across screens of
/// different logical heights. On a tall screen `scale == 1` (the reference
/// design); on a shorter one (e.g. a 1080-point Full-HD or a default-scaled 4K)
/// it shrinks so the bar never eats an oversized slice of the screen.
/// Which clicks in the panel are about a card.
///
/// Everything the panel does to a click before its views see it is about cards — ⌘-click selects
/// one, a double-click pastes one — and each of those *consumes* the event. Over the toolbar there
/// is no card to act on, so consuming it there does nothing but destroy the press. That is what
/// made the filter button swallow clicks when it was leaned on: every second press came in with
/// `clickCount == 2`, went out as `doubleClickInPanel`, matched no card and vanished. Neither the
/// button nor the sheet's own state could see any of it happen.
/// The card commands that are a plain ⌘ plus a letter.
///
/// `nil` for every other letter, so ⌘F, ⌘W and the rest are left to whoever else wants them —
/// the monitor swallows only what it can act on.
enum CardCommandKey {
    static func command(for key: String) -> Notification.Name? {
        switch key {
        case "r": return .renameSelectedItem
        case "e": return .editSelectedItem
        case "o": return .openSelectedItem
        default:  return nil
        }
    }
}

enum PanelClickRegion {
    /// The strip along the top of the panel the toolbar occupies: the search field, its filter
    /// button, the tabs and the ⋯ menu. The toolbar is ~58pt tall and always sits at the top of
    /// the panel, whichever screen edge the panel itself is on; the rest is slack.
    static let toolbarStrip: CGFloat = 75

    /// `barTop` is the top of the bar view, not of the window: the window is taller than the bar
    /// while the reveal animation runs.
    static func isOverCardList(_ locationInWindow: NSPoint, barTop: CGFloat) -> Bool {
        locationInWindow.y < barTop - toolbarStrip
    }
}

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
    /// Height of a card's footer strip (the character count and ⌘-number badge). Shared with
    /// `RichTextRenderer.cardPreviewSize` so the rasterised preview matches the content rect.
    static let cardFooterHeight: CGFloat = 30
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

    /// Where the panel's window sits while the bar is travelling, and how far the bar is displaced
    /// at the start of that journey.
    ///
    /// The window is stretched to cover the bar *and* the runway it slides along, so the whole
    /// reveal is a Core Animation translate of one view inside a window that never moves.
    ///
    /// Moving the window instead is what made the reveal stutter, and it was measured rather than
    /// guessed: `sample` put 246 of 265 samples taken inside each per-frame `setFrameOrigin` in
    /// `-[NSWMWindowCoordinator clearDisplayAffinityForWindow:]` -> `entanglingFenceHandle` ->
    /// `+[CAFenceHandle newFenceFromDefaultServer]` -> `mach_msg`, a synchronous round trip to the
    /// window server on every single frame. With a behind-window glass backdrop to resample, and a
    /// window that starts on no display at all, several of those blocked 10-25ms each and the bar
    /// visibly hitched. Pacing them better is not available either: a `CADisplayLink` taken from the
    /// panel never fires while the panel is off-screen, so there is no vsync to lock to.
    struct PanelSlideGeometry: Equatable {
        /// The stretched window frame: the bar plus its runway.
        let windowFrame: NSRect
        /// Where the bar rests inside that window, in the container's coordinates.
        let barFrame: NSRect
        /// How far the bar is displaced from `barFrame` when it has not arrived yet.
        let offset: CGSize

        /// Where the bar sits before it has arrived.
        var displacedBarFrame: NSRect {
            barFrame.offsetBy(dx: offset.width, dy: offset.height)
        }
    }

    /// How far past its own edge the bar travels, on top of its thickness: the gap it floats above
    /// the screen edge, plus enough to take its shadow with it. The bar used to be moved this far as
    /// a window, so keeping the number identical keeps the reveal looking exactly as it did.
    static let slideSlack: CGFloat = screenInset + 40

    static func slideGeometry(for target: NSRect, position: String) -> PanelSlideGeometry {
        switch position {
        case "top":
            let travel = target.height + slideSlack
            return PanelSlideGeometry(
                windowFrame: NSRect(x: target.minX, y: target.minY,
                                    width: target.width, height: target.height + travel),
                barFrame: NSRect(x: 0, y: 0, width: target.width, height: target.height),
                offset: CGSize(width: 0, height: travel))
        case "left":
            let travel = target.width + slideSlack
            return PanelSlideGeometry(
                windowFrame: NSRect(x: target.minX - travel, y: target.minY,
                                    width: target.width + travel, height: target.height),
                barFrame: NSRect(x: travel, y: 0, width: target.width, height: target.height),
                offset: CGSize(width: -travel, height: 0))
        case "right":
            let travel = target.width + slideSlack
            return PanelSlideGeometry(
                windowFrame: NSRect(x: target.minX, y: target.minY,
                                    width: target.width + travel, height: target.height),
                barFrame: NSRect(x: 0, y: 0, width: target.width, height: target.height),
                offset: CGSize(width: travel, height: 0))
        default:
            let travel = target.height + slideSlack
            return PanelSlideGeometry(
                windowFrame: NSRect(x: target.minX, y: target.minY - travel,
                                    width: target.width, height: target.height + travel),
                barFrame: NSRect(x: 0, y: travel, width: target.width, height: target.height),
                offset: CGSize(width: 0, height: -travel))
        }
    }

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
