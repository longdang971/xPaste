import AppKit
import SwiftUI

/// The notch features: a banner when something is copied, a shelf of recent items when the pointer
/// rests on the camera housing, and a drop target on the housing that saves whatever is dropped.
///
/// Only on a screen that has a housing. With none attached — an external display on its own, the
/// lid closed, or a resolution that letterboxes the menu bar below the housing — there is no
/// window at all.
final class NotchController {
    static let shared = NotchController()

    enum Keys {
        static let copyBanner = "notchCopyBanner"
        static let hoverShelf = "notchHoverShelf"
        static let dropToSave = "notchDropToSave"
    }

    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    private var bannerEnabled: Bool { Self.flag(Keys.copyBanner) }
    private var shelfEnabled: Bool { Self.flag(Keys.hoverShelf) }
    private var dropEnabled: Bool { Self.flag(Keys.dropToSave) }

    private let model = NotchModel()
    private var panel: NotchPanel?
    private var container: NotchContainerView?
    private var geometry: NotchGeometry?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?

    /// The full panel is on screen: the notch keeps out of its way.
    private var mainPanelVisible = false

    /// How long the pointer has to rest on the housing before the shelf opens. Long enough that
    /// sweeping across the top of the screen does not open it.
    private static let hoverDelay: TimeInterval = 0.15
    private static let toastDuration: TimeInterval = 1.6
    /// Long enough for `NotchView.animation` to finish shrinking before the window does.
    private static let settleDelay: TimeInterval = 0.45

    private init() {}

    func start() {
        model.onPick = { [weak self] in self?.paste($0) }
        model.onOpenPanel = { [weak self] in
            self?.setMode(.idle)
            NotificationCenter.default.post(name: .toggleClipboard, object: nil)
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() },
            center.addObserver(forName: UserDefaults.didChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.rebuild() },
            center.addObserver(forName: .screenSharingVisibilityChanged,
                               object: nil, queue: .main) { [weak self] _ in self?.applySharingType() },
            center.addObserver(forName: .panelDidOpen, object: nil, queue: .main) { [weak self] _ in
                self?.mainPanelVisible = true
                self?.setMode(.idle)
            },
            // Will-hide rather than did-hide: the panel posts did-hide only from the end of its
            // slide, and skips it when the slide is cut short by reopening. Missing one would leave
            // every notch feature switched off until the next time the panel opened and closed.
            center.addObserver(forName: .panelWillHide, object: nil, queue: .main) { [weak self] _ in
                self?.mainPanelVisible = false
            },
        ]
        rebuild()
    }

    // MARK: - Window

    /// Creates, moves or removes the window to match the screens and the settings. Cheap when
    /// nothing changed, which is most calls: it runs on every write to the defaults.
    private func rebuild() {
        let anyEnabled = bannerEnabled || shelfEnabled || dropEnabled
        guard anyEnabled,
              let screen = NSScreen.screens.first(where: \.hasNotch),
              let geo = NotchGeometry.of(screen) else {
            tearDown()
            return
        }
        if panel == nil { makePanel() }
        if geo != geometry {
            geometry = geo
            model.notchSize = geo.notchSize
            mode = .idle
            model.mode = .idle
            applyFrame(for: .idle)
        }
        container?.acceptsDrops = dropEnabled
        updateMouseHandling()
        updateMonitors()
    }

    private func makePanel() {
        let p = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        // Above the menu bar, which it draws over.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NotchHostingView(rootView: NotchView(model: model))
        host.sizingOptions = []
        let box = NotchContainerView()
        box.addSubview(host)
        host.autoresizingMask = [.width, .height]
        box.onDragEntered = { [weak self] in self?.dragEntered() ?? false }
        box.onDragExited = { [weak self] in self?.dragExited() }
        box.onDrop = { [weak self] in self?.drop($0) ?? false }
        p.contentView = box
        container = box
        panel = p
        applySharingType()
        p.orderFrontRegardless()
    }

    private func tearDown() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        container = nil
        geometry = nil
        mode = .idle
        model.mode = .idle
    }

    private func applySharingType() {
        panel?.sharingType = UserDefaults.standard.bool(forKey: "showDuringScreenSharing") ? .readOnly : .none
    }

    private func applyFrame(for mode: NotchModel.Mode) {
        guard let geometry, let panel else { return }
        panel.setFrame(geometry.frame(for: model.size(of: mode)), display: true)
    }

    /// The state the notch is in or on its way to. `model.mode` can trail it by a run-loop turn —
    /// see `setMode` — so every decision reads this.
    private var mode: NotchModel.Mode = .idle

    /// Switches state. The window is never resized while the shape animates: it grows to cover
    /// both states first and shrinks to the new one once the animation is over. Moving a window
    /// costs a WindowServer round trip per frame, which is what made the panel's slide stutter.
    private func setMode(_ new: NotchModel.Mode) {
        guard let geometry, let panel, mode != new else { return }
        mode = new
        settleWork?.cancel()
        if new == .shelf { model.shelfItems = NotchShelfItems.recent(ClipboardStore.shared.items) }
        let current = panel.frame.size
        let target = model.size(of: new)
        let union = CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
        if union != current {
            // Grown and laid out before the state changes, in a pass of its own. Done in the same
            // update as the change, SwiftUI animated the window's new width too: the shape, centred
            // in a window that had just doubled, slid in from the left instead of growing out of
            // the housing to both sides.
            panel.setFrame(geometry.frame(for: union), display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { [weak self] in self?.showMode() }
        } else {
            showMode()
        }
        if union != target {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.mode == new else { return }
                self.applyFrame(for: new)
                self.updateMouseHandling()
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
        }
    }

    private func showMode() {
        guard model.mode != mode else { return }
        model.mode = mode
        updateMouseHandling()
    }

    /// Which states take the pointer. A banner is only something to read, and must not swallow
    /// clicks meant for the window under it; idle needs the pointer only to catch a drag.
    ///
    /// Idle also lets everything through while the window is still the size of the state it left:
    /// for the length of the closing animation it covers a banner's or a shelf's worth of the top
    /// of the screen, and a click on a browser's tabs in that moment went to the notch and was
    /// lost — after every single copy.
    private func updateMouseHandling() {
        guard let panel else { return }
        switch mode {
        case .idle:
            let settling = panel.frame.size != model.size(of: .idle)
            panel.ignoresMouseEvents = !dropEnabled || settling
        case .toast: panel.ignoresMouseEvents = true
        case .shelf, .drop: panel.ignoresMouseEvents = false
        }
    }

    // MARK: - Banner

    /// Shows a copy that has just been saved. Only while the notched screen is the one in use:
    /// a banner up there is no use to someone working on another display.
    func showSaved(_ item: ClipboardItem, title: String = "Copied") {
        guard bannerEnabled, !mainPanelVisible, let geometry, panel != nil else { return }
        guard NSScreen.main?.frame == geometry.screenFrame else { return }
        switch mode {
        case .shelf, .drop: return
        case .idle, .toast: break
        }
        let source = item.sourceAppBundleID.flatMap { AppNameResolver.shared.name(for: $0) }
        show(NotchToast.make(for: item, title: source.map { "\(title) from \($0)" } ?? title))
    }

    private func show(_ toast: NotchToast) {
        toastWork?.cancel()
        setMode(.toast(toast))
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .toast(let shown) = self.mode, shown == toast else { return }
            self.setMode(.idle)
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration, execute: work)
    }

    // MARK: - Shelf

    private func updateMonitors() {
        let wanted = shelfEnabled
        if wanted, monitors.isEmpty {
            let moved: NSEvent.EventTypeMask = [.mouseMoved]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
                self?.pointerMoved(NSEvent.mouseLocation)
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
                self?.pointerMoved(NSEvent.mouseLocation)
                return event
            }) { monitors.append(m) }
            // A click anywhere else closes the shelf, as a menu would.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown],
                                                         handler: { [weak self] _ in
                guard self?.mode == .shelf else { return }
                self?.setMode(.idle)
            }) { monitors.append(m) }
        } else if !wanted, !monitors.isEmpty {
            removeMonitors()
            if mode == .shelf { setMode(.idle) }
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func pointerMoved(_ point: NSPoint) {
        guard let geometry, !mainPanelVisible else { return }
        switch mode {
        case .idle, .toast:
            // The housing plus a little either side: the top row of pixels is where a pointer
            // thrown at the top of the screen lands.
            let zone = geometry.notchRect.insetBy(dx: -6, dy: 0)
            if zone.contains(point) || (point.y >= geometry.screenFrame.maxY - 1 && zone.minX...zone.maxX ~= point.x) {
                guard hoverWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    self?.hoverWork = nil
                    self?.openShelf()
                }
                hoverWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
            } else {
                hoverWork?.cancel()
                hoverWork = nil
            }
        case .shelf:
            // The shelf as drawn, which is narrower than six cards' worth when there are fewer.
            let keep = geometry.frame(for: model.size(of: .shelf)).insetBy(dx: -10, dy: -10)
            if keep.contains(point) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.collapseWork = nil
                    guard self?.mode == .shelf else { return }
                    self?.setMode(.idle)
                }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            }
        case .drop:
            break
        }
    }

    private func openShelf() {
        guard shelfEnabled, !mainPanelVisible else { return }
        toastWork?.cancel()
        setMode(.shelf)
    }

    /// Pastes an item into whatever app is in front. The notch never takes focus, so that app is
    /// still the one with the cursor in it.
    private func paste(_ item: ClipboardItem) {
        setMode(.idle)
        let store = ClipboardStore.shared
        if UserDefaults.standard.bool(forKey: "alwaysPastePlainText"), item.text != nil {
            let text = store.fullText(for: item) ?? item.displayText
            ClipboardMonitor.shared.writeOwned { board in
                board.clearContents()
                board.setString(text, forType: .string)
            }
        } else {
            item.copyToPasteboard()
        }
        store.moveToTop(item)
        guard AccessibilityPermission.isTrusted else {
            show(NotchToast(title: "Copied — press ⌘V to paste", text: NotchText.summary(of: item)))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
            down?.flags = .maskCommand
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Drop

    /// Whether a drag may land, and if so opens the drop target. Refused while the full panel is
    /// up: it was accepted anyway, with no target on screen, and saved without a word.
    private func dragEntered() -> Bool {
        guard dropEnabled, !mainPanelVisible else { return false }
        collapseWork?.cancel()
        collapseWork = nil
        toastWork?.cancel()
        setMode(.drop)
        return true
    }

    /// Deferred a moment: growing the window under a drag can report an exit and a re-entry.
    private func dragExited() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.collapseWork = nil
            guard self?.mode == .drop else { return }
            self?.setMode(.idle)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func drop(_ board: NSPasteboard) -> Bool {
        collapseWork?.cancel()
        collapseWork = nil
        guard var item = ClipboardItem.from(pasteboard: board) else {
            setMode(.idle)
            return false
        }
        item.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let shown = item
        ClipboardStore.shared.add(item)
        if item.type == .image, let data = item.imageData {
            OCRService.scan(itemID: item.id, imageData: data)
        }
        SoundEffects.play(.copy)
        // Through `show` rather than `showSaved`: the drop happened on this screen, whichever one
        // has focus.
        show(NotchToast.make(for: shown, title: "Saved to xPaste"))
        return true
    }
}

/// Never key: a click on the shelf must leave the keyboard with the app the user is typing in.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click. The panel is never key and the app never active, so without this the
/// first click on a card would only "activate" the window and do nothing.
private final class NotchHostingView: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The window's content view and its drop target.
private final class NotchContainerView: NSView {
    var onDragEntered: () -> Bool = { false }
    var onDragExited: () -> Void = {}
    var onDrop: (NSPasteboard) -> Bool = { _ in false }

    var acceptsDrops = false {
        didSet {
            guard acceptsDrops != oldValue else { return }
            if acceptsDrops {
                registerForDraggedTypes([.fileURL, .URL, .string, .rtf, .html, .tiff, .png])
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// A drag that starts inside xPaste — a card out of the panel — is already in the history.
    private func accepts(_ info: NSDraggingInfo) -> Bool {
        acceptsDrops && info.draggingSource == nil
    }

    /// Whether the drag in progress was let in. Updates and the drop itself answer the same as
    /// the entry did, so a drag refused on the way in cannot land anyway.
    private var admitted = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        admitted = accepts(sender) && onDragEntered()
        return admitted ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        admitted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        admitted = false
        onDragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard admitted else { return false }
        admitted = false
        return onDrop(sender.draggingPasteboard)
    }
}
