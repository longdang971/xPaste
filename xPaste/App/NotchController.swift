import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    private var host: NSView?
    private let dragSource = NotchDragSource()
    private var geometry: NotchGeometry?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?

    /// The full panel is on screen: the notch keeps out of its way.
    private var mainPanelVisible = false

    /// The pointer is on the banner. It then takes the mouse, for its buttons, and stays up until
    /// the pointer leaves.
    private var bannerHovered = false

    /// How long the pointer has to rest on the housing before the shelf opens. Long enough that
    /// sweeping across the top of the screen does not open it.
    private static let hoverDelay: TimeInterval = 0.15
    private static let toastDuration: TimeInterval = 1.6
    /// How long a banner lingers once the pointer has left it.
    private static let bannerLeaveDelay: TimeInterval = 0.6
    /// Long enough for `NotchView.animation` to finish shrinking before the window does.
    private static let settleDelay: TimeInterval = 0.45

    private init() {}

    func start() {
        model.onPick = { [weak self] in self?.paste($0) }
        model.onOpenPanel = { [weak self] in
            self?.setMode(.idle)
            NotificationCenter.default.post(name: .toggleClipboard, object: nil)
        }
        model.onTogglePin = { [weak self] in self?.togglePin($0) }
        model.onRemove = { [weak self] in self?.remove($0) }
        model.onCopyText = { [weak self] in self?.copyText(from: $0) }
        dragSource.onEnded = { [weak self] in self?.dragEnded($0, at: $1, accepted: $2) }
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
        box.onDragEntered = { [weak self] in self?.dragEntered($0) ?? false }
        box.onDragMoved = { [weak self] in self?.dragMoved($0) }
        box.onDragExited = { [weak self] in self?.dragExited() }
        box.onDrop = { [weak self] in self?.drop($0, at: $1) ?? false }
        p.onDragOut = { [weak self] in self?.dragOut($0, from: $1) ?? false }
        p.contentView = box
        container = box
        self.host = host
        panel = p
        applySharingType()
        p.orderFrontRegardless()
    }

    private func tearDown() {
        removeMonitors()
        panel?.orderOut(nil)
        panel = nil
        container = nil
        host = nil
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
        bannerHovered = false
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
        case .toast: panel.ignoresMouseEvents = !bannerHovered
        case .shelf, .drop: panel.ignoresMouseEvents = false
        }
    }

    // MARK: - Banner

    /// Shows a copy that has just been saved. Only while the notched screen is the one in use:
    /// a banner up there is no use to someone working on another display.
    /// `stored` is what the history holds for it, when that is not `item` itself — a copy of
    /// something already pinned lands on the pinned item, and the banner's buttons must act on
    /// that one. `item` still draws the banner: it is the one carrying the picture.
    func showSaved(_ item: ClipboardItem, storedAs stored: ClipboardItem? = nil, title: String = "Copied") {
        guard bannerEnabled, !mainPanelVisible, let geometry, panel != nil else { return }
        guard NSScreen.main?.frame == geometry.screenFrame else { return }
        switch mode {
        case .shelf, .drop: return
        case .idle, .toast: break
        }
        let source = item.sourceAppBundleID.flatMap { AppNameResolver.shared.name(for: $0) }
        show(NotchToast.make(for: item, storedAs: stored,
                             title: source.map { "\(title) from \($0)" } ?? title))
    }

    private func show(_ toast: NotchToast, for duration: TimeInterval = NotchController.toastDuration) {
        setMode(.toast(toast))
        scheduleDismiss(after: duration)
        // A banner that lands under a pointer already resting there gets no move to notice it by.
        bannerPointerMoved(NSEvent.mouseLocation)
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        toastWork?.cancel()
        guard case .toast(let toast) = mode else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .toast(let shown) = self.mode, shown == toast else { return }
            self.setMode(.idle)
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Lets the banner take the mouse while the pointer is on it, and only then: the rest of the
    /// time it must not swallow a click meant for the tabs under it. Held up while hovered, so it
    /// does not vanish as the pointer arrives at a button.
    private func bannerPointerMoved(_ point: NSPoint) {
        guard let geometry, case .toast(let toast) = mode else { return }
        let over = toast.itemID != nil && geometry.frame(for: model.size(of: mode)).contains(point)
        guard over != bannerHovered else { return }
        bannerHovered = over
        updateMouseHandling()
        if over {
            watchBannerHover()
        } else {
            scheduleDismiss(after: Self.bannerLeaveDelay)
        }
    }

    /// Looks again at where the pointer is while the banner is held up, rather than trusting a
    /// move to arrive when it leaves: one thrown off the top of the screen, or onto another
    /// display, may send none the monitors see — and the banner would then stay up for good.
    private func watchBannerHover() {
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bannerHovered else { return }
            self.bannerPointerMoved(NSEvent.mouseLocation)
            if self.bannerHovered { self.watchBannerHover() }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Banner buttons

    private func liveItem(_ id: UUID) -> ClipboardItem? {
        ClipboardStore.shared.items.first { $0.id == id }
    }

    private func togglePin(_ id: UUID) {
        guard let item = liveItem(id) else { return }
        ClipboardStore.shared.togglePin(item)
    }

    /// Takes the copy out of the history — the password copied by mistake. The clipboard keeps it:
    /// whatever it was copied for may still be about to be pasted.
    private func remove(_ id: UUID) {
        guard let item = liveItem(id) else { return }
        ClipboardStore.shared.delete(item)
        show(NotchToast(title: "Removed from history", text: NotchText.summary(of: item),
                        symbol: "trash"), for: 1)
    }

    /// Copies the text in a picture, as an item of its own from the same app.
    private func copyText(from id: UUID) {
        guard let item = liveItem(id), item.type == .image else { return }
        let store = ClipboardStore.shared
        Task { @MainActor [weak self] in
            var text = item.ocrText ?? ""
            if item.ocrText == nil, let data = item.imageData ?? store.imageBytes(for: id) {
                text = await OCRService.recognizeText(in: data)
            }
            // The never-store patterns, as the background scan obeys them: a key photographed
            // rather than copied is still a key.
            text = OCRService.storable(text, patterns: ExclusionRules.storedPatterns())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.deliverText(text, source: item.sourceAppBundleID)
        }
    }

    /// Puts text read out of a picture on the clipboard and in the history, as an item of its own
    /// from `source`, and says so — or says there was none.
    ///
    /// Said only if the notch is free to say it. Reading can take long enough — most of a minute
    /// on the first read after a new build — for the shelf to have been opened, a new drag to be
    /// over the drop target, or the panel to be up; a banner then would close the shelf, close
    /// the target under the drag, or sit over the panel.
    private func deliverText(_ text: String, source: String?) {
        let canSay: Bool = {
            guard !mainPanelVisible else { return false }
            if case .toast = mode { return true }
            return mode == .idle
        }()
        guard !text.isEmpty else {
            if canSay {
                show(NotchToast(title: "No text found in image", text: "", symbol: "text.viewfinder"))
            }
            return
        }
        ClipboardMonitor.shared.writeOwned { board in
            board.clearContents()
            board.setString(text, forType: .string)
        }
        var copied = ClipboardItem(type: ClipboardItem.contentType(for: text), text: text)
        copied.sourceAppBundleID = source
        let stored = ClipboardStore.shared.add(copied)
        SoundEffects.play(.copy)
        if canSay { show(NotchToast.make(for: copied, storedAs: stored, title: "Text copied")) }
    }

    // MARK: - Shelf

    private func updateMonitors() {
        // The banner listens too: it takes the mouse only while the pointer is on it. So does the
        // drop target, to open before a drag reaches the top edge — see `contentDragMoved`.
        let wanted = shelfEnabled || bannerEnabled || dropEnabled
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
                guard let self else { return }
                self.dragBoardCount = NSPasteboard(name: .drag).changeCount
                guard self.mode == .shelf else { return }
                self.setMode(.idle)
            }) { monitors.append(m) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged], handler: { [weak self] _ in
                self?.contentDragMoved(NSEvent.mouseLocation)
            }) { monitors.append(m) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
                self?.contentDragEnded()
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
            bannerPointerMoved(point)
            guard shelfEnabled else { return }
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

    // MARK: - Drag out

    /// Turns a press on a shelf tile that moved into a drag of that item. The shelf folds away as
    /// the drag starts, so it is not lying over whatever the item is about to be dropped on.
    private func dragOut(_ event: NSEvent, from origin: NSPoint) -> Bool {
        guard mode == .shelf, let host, let container else { return false }
        let local = host.convert(origin, from: nil)
        let top = host.isFlipped ? local : NSPoint(x: local.x, y: host.bounds.height - local.y)
        guard let hit = model.tileFrames.first(where: { $0.value.contains(top) }),
              let item = model.shelfItems.first(where: { $0.id == hit.key }) else { return false }
        let frame = hit.value
        let inHost = host.isFlipped ? frame
            : NSRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        let image = CardDragSourceView.snapshot(of: inHost, in: host, radius: NotchLayout.shelfTileRadius)
        let dragged = NSDraggingItem(pasteboardWriter: CardDragSourceView.nativeWriter(for: item))
        dragged.setDraggingFrame(container.convert(inHost, from: host), contents: image)
        dragSource.item = item
        container.beginDraggingSession(with: [dragged], event: event, source: dragSource)
        collapseWork?.cancel()
        collapseWork = nil
        setMode(.idle)
        return true
    }

    /// As the panel's own drag does: focus the field it landed on, and bring the item to the front.
    private func dragEnded(_ item: ClipboardItem, at point: NSPoint, accepted: Bool) {
        guard accepted else { return }
        DropTargetResolver.focus(under: point)
        if let live = liveItem(item.id) { ClipboardStore.shared.moveToTop(live) }
    }

    // MARK: - Drop

    /// Whether a drag may land, and if so opens the drop target. Refused while the full panel is
    /// up: it was accepted anyway, with no target on screen, and saved without a word.
    private func dragEntered(_ board: NSPasteboard) -> Bool {
        guard dropEnabled, !mainPanelVisible else { return false }
        collapseWork?.cancel()
        collapseWork = nil
        toastWork?.cancel()
        // Set before the mode: the target's width depends on how many zones it has.
        if mode != .drop {
            model.dropZones = NotchDropZone.zones(carryingImages: Self.carriesImages(board))
            model.dropTarget = .save
            model.dropZoneFrames = [:]
        }
        setMode(.drop)
        return true
    }

    /// Follows the drag across the zones. Before the zones are laid out there is nothing to
    /// measure against, and the target stays where it was.
    private func dragMoved(_ windowPoint: NSPoint) {
        guard mode == .drop, let zone = zone(at: windowPoint), zone != model.dropTarget else { return }
        model.dropTarget = zone
    }

    private func zone(at windowPoint: NSPoint) -> NotchDropZone? {
        guard let host else { return nil }
        let local = host.convert(windowPoint, from: nil)
        return NotchDropZone.nearest(to: local.x, in: model.dropZoneFrames)
    }

    /// Whether a drag carries a picture: the bitmap itself, or an image file from Finder.
    private static func carriesImages(_ board: NSPasteboard) -> Bool {
        if board.types?.contains(where: { $0 == .tiff || $0 == .png }) == true { return true }
        return !imageFiles(on: board).isEmpty
    }

    private static func imageFiles(on board: NSPasteboard) -> [URL] {
        board.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL] ?? []
    }

    /// Deferred a moment: growing the window under a drag can report an exit and a re-entry.
    /// Kept open while the drag is still just around the target: it is `contentDragMoved` that
    /// closes it once the drag has really gone.
    private func dragExited() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseWork = nil
            guard self.mode == .drop, !self.dropKeepZone.contains(NSEvent.mouseLocation) else { return }
            self.setMode(.idle)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Opening ahead of the drag

    /// The drag pasteboard's count when the mouse last went down. A drag that carries something
    /// writes to that pasteboard as it starts; one that does not — a window being moved, text
    /// being selected — leaves it alone, and must not open anything.
    private var dragBoardCount = NSPasteboard(name: .drag).changeCount

    /// Where a drag on its way up opens the target: under and around the housing, well short of
    /// the top edge. Pushed against that edge, a drag opens Mission Control's Spaces bar, which
    /// takes the drag over and covers the screen; open here, the zones are already under the
    /// pointer before it gets there.
    private var dropApproachZone: NSRect {
        guard let notch = geometry?.notchRect else { return .zero }
        return NSRect(x: notch.minX - 60, y: notch.minY - 60,
                      width: notch.width + 120, height: notch.height + 60)
    }

    /// While the target is open: the target and a margin around it. Leaving this closes it.
    private var dropKeepZone: NSRect {
        guard let geometry else { return .zero }
        let frame = geometry.frame(for: model.size(of: .drop))
        return NSRect(x: frame.minX - 30, y: frame.minY - 30,
                      width: frame.width + 60, height: frame.height + 30)
    }

    /// A drag from another app moved. Only the global monitor sees these, and only while the
    /// pointer is outside the notch's own window or the drag belongs to someone else — which is
    /// every drag the target accepts.
    private func contentDragMoved(_ point: NSPoint) {
        guard dropEnabled, !mainPanelVisible, geometry != nil else { return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragBoardCount else { return }
        if mode == .drop {
            guard !dropKeepZone.contains(point) else { return }
            collapseWork?.cancel()
            collapseWork = nil
            setMode(.idle)
        } else if dropApproachZone.contains(point) {
            _ = dragEntered(board)
        }
    }

    /// The button came up. A drop on the target has already turned it into a banner; anything
    /// still showing the zones now was let go somewhere else.
    private func contentDragEnded() {
        guard mode == .drop else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self?.mode == .drop else { return }
            self?.setMode(.idle)
        }
    }

    private func drop(_ board: NSPasteboard, at windowPoint: NSPoint) -> Bool {
        collapseWork?.cancel()
        collapseWork = nil
        let zone = self.zone(at: windowPoint) ?? model.dropTarget
        if zone == .text { return dropForText(board) }
        guard var item = ClipboardItem.from(pasteboard: board) else {
            setMode(.idle)
            return false
        }
        item.sourceAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        item.isPinned = zone == .pin
        let stored = ClipboardStore.shared.add(item)
        // Not when it landed on a pinned item already in the history: that one has been read.
        if stored.id == item.id, item.type == .image, let data = item.imageData {
            OCRService.scan(itemID: item.id, imageData: data)
        }
        SoundEffects.play(.copy)
        // Through `show` rather than `showSaved`: the drop happened on this screen, whichever one
        // has focus.
        show(NotchToast.make(for: item, storedAs: stored,
                             title: zone == .pin ? "Saved & pinned" : "Saved to xPaste"))
        return true
    }

    /// Reads the text out of the pictures dropped and copies it. The pictures themselves are not
    /// kept: the zone asked for their text, and a save was the zone next to it.
    private func dropForText(_ board: NSPasteboard) -> Bool {
        let files = Self.imageFiles(on: board)
        let bitmap = files.isEmpty
            ? (board.data(forType: .png) ?? board.data(forType: .tiff))
            : nil
        guard !files.isEmpty || bitmap != nil else {
            setMode(.idle)
            return false
        }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Up until the text arrives, which is usually a second — but the first read after a new
        // build of the app loads Vision's model, measured at nearly a minute.
        var reading = NotchToast(title: "Reading text…", text: "", symbol: "text.viewfinder")
        reading.busy = true
        show(reading, for: 120)
        Task { @MainActor [weak self] in
            let pieces: [String] = await Task.detached(priority: .userInitiated) {
                let images = bitmap.map { [$0] } ?? files.compactMap { try? Data(contentsOf: $0) }
                var read: [String] = []
                for data in images { read.append(await OCRService.recognizeText(in: data)) }
                return read
            }.value
            let text = OCRService.storable(
                pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n"),
                patterns: ExclusionRules.storedPatterns())
            self?.deliverText(text, source: source)
        }
        return true
    }
}

/// Never key: a click on the shelf must leave the keyboard with the app the user is typing in.
///
/// Also where a press on a tile becomes a drag, the way the full panel's window does it: the tile
/// is a button, and a button never says that the pointer left it with the mouse still down.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The drag-threshold event and where the press began, in window coordinates. True when it
    /// started a drag, which then has the rest of the gesture.
    var onDragOut: (NSEvent, NSPoint) -> Bool = { _, _ in false }
    private var pressOrigin: NSPoint?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressOrigin = event.locationInWindow
        case .leftMouseDragged:
            if let origin = pressOrigin,
               DragPaste.exceedsThreshold(from: origin, to: event.locationInWindow) {
                pressOrigin = nil
                if onDragOut(event, origin) { return }
            }
        case .leftMouseUp:
            pressOrigin = nil
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// The source of a drag out of the shelf. Its own object, held by the controller, rather than the
/// tile's view: the shelf folds away as the drag starts, and the tile with it.
private final class NotchDragSource: NSObject, NSDraggingSource {
    var item: ClipboardItem?
    var onEnded: (ClipboardItem, NSPoint, Bool) -> Void = { _, _, _ in }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let item else { return }
        self.item = nil
        onEnded(item, screenPoint, !operation.isEmpty)
    }
}

/// Takes the first click. The panel is never key and the app never active, so without this the
/// first click on a card would only "activate" the window and do nothing.
private final class NotchHostingView: NSHostingView<NotchView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The window's content view and its drop target.
private final class NotchContainerView: NSView {
    var onDragEntered: (NSPasteboard) -> Bool = { _ in false }
    var onDragMoved: (NSPoint) -> Void = { _ in }
    var onDragExited: () -> Void = {}
    var onDrop: (NSPasteboard, NSPoint) -> Bool = { _, _ in false }

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
        admitted = accepts(sender) && onDragEntered(sender.draggingPasteboard)
        if admitted { onDragMoved(sender.draggingLocation) }
        return admitted ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if admitted { onDragMoved(sender.draggingLocation) }
        return admitted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        admitted = false
        onDragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard admitted else { return false }
        admitted = false
        return onDrop(sender.draggingPasteboard, sender.draggingLocation)
    }
}
