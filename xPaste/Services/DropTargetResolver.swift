import AppKit

/// Which application — and which of its windows — a drag was released over.
///
/// A drop does not bring its target forward: the text lands, but the keyboard stays with whatever
/// was frontmost before, so ⌘Z went somewhere that had nothing to undo. Knowing where the drop landed
/// is what lets `focus(under:)` hand the keyboard to it.
enum DropTargetResolver {

    /// One on-screen window, as much of it as the choice depends on.
    struct Window: Equatable {
        let pid: pid_t
        /// Top-left origin, the way `CGWindowListCopyWindowInfo` reports it.
        let bounds: CGRect
        /// `kCGWindowLayer`. Ordinary application windows are 0; the Dock, the menu bar and the rest
        /// of the system's furniture sit above.
        let layer: Int
    }

    /// The owner of the frontmost ordinary window containing `point`.
    ///
    /// `windows` must be front-to-back, which is the order `CGWindowListCopyWindowInfo` returns them.
    static func owner(of point: CGPoint, in windows: [Window], excluding excluded: pid_t) -> pid_t? {
        window(at: point, in: windows, excluding: excluded)?.pid
    }

    static func window(at point: CGPoint, in windows: [Window], excluding excluded: pid_t) -> Window? {
        windows.first { $0.layer == 0 && $0.pid != excluded && $0.bounds.contains(point) }
    }

    /// A dragging session's screen point, in the window list's coordinates.
    ///
    /// Sessions report a bottom-left origin; the window list uses top-left, both measured against the
    /// primary display. Verified against a real session: a release at a Core Graphics y of 700 on a
    /// 1440-point-tall display was reported as y 740.
    static func flip(_ point: NSPoint, primaryTop: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryTop - point.y)
    }

    /// The application under a point given in a dragging session's screen coordinates.
    static func pid(under screenPoint: NSPoint) -> pid_t? {
        guard let primary = NSScreen.screens.first else { return nil }
        return owner(of: flip(screenPoint, primaryTop: primary.frame.maxY),
                     in: onScreenWindows(),
                     excluding: ProcessInfo.processInfo.processIdentifier)
    }

    /// Brings the application a drop landed in to the front, with the window it landed in as its key
    /// window, so the keyboard — ⌘Z to take the drop back, first of all — goes where the drop went.
    ///
    /// Activating the application alone brings up whichever of its windows was key before, which is
    /// not the one dropped into when it has several. That window is raised over Accessibility,
    /// matched by frame; without Accessibility, or when nothing matches, activating is all there is.
    static func focus(under screenPoint: NSPoint) {
        guard let primary = NSScreen.screens.first else { return }
        let point = flip(screenPoint, primaryTop: primary.frame.maxY)
        guard let target = window(at: point, in: onScreenWindows(),
                                  excluding: ProcessInfo.processInfo.processIdentifier),
              let app = NSRunningApplication(processIdentifier: target.pid)
        else { return }
        raise(target)
        app.activate(options: [])
        // Bringing the window forward is not enough on its own: ⌘Z goes to whatever inside it has
        // focus, and a drop does not give focus to the field it landed in — the user had to click
        // back into it first. Activation is asynchronous, so the field is focused once the app has
        // come forward, and once more if the first attempt landed before it had.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard !focusEditable(at: point, pid: target.pid) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                _ = focusEditable(at: point, pid: target.pid)
            }
        }
    }

    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String,
    ]

    /// Gives keyboard focus to the editable element under `point` — top-left coordinates — and says
    /// whether it now has it.
    ///
    /// Focus is set over Accessibility rather than by clicking there: a click could press a button or
    /// follow a link, and would drop the selection a drop often leaves on what it inserted. Anything
    /// that is not a text field is left alone — activating the application was all it needed.
    @discardableResult
    static func focusEditable(at point: CGPoint, pid: pid_t) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                               Float(point.x), Float(point.y), &hit) == .success,
              let hit, owner(of: hit) == pid,
              let field = editable(from: hit)
        else { return false }
        if isFocused(field) { return true }
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return isFocused(field)
    }

    /// The text field `element` is, or sits inside. Browsers name the editing host of a rich-text
    /// area directly; native controls are found by walking up to the nearest text role.
    private static func editable(from element: AXUIElement) -> AXUIElement? {
        if let host: AXUIElement = attribute(element, "AXEditableAncestor") { return host }
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let el = current else { return nil }
            if let role: String = attribute(el, kAXRoleAttribute), editableRoles.contains(role) {
                return el
            }
            current = attribute(el, kAXParentAttribute)
        }
        return nil
    }

    private static func isFocused(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXFocusedAttribute) as Bool?) == true
    }

    private static func owner(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value as? T
    }

    private static func raise(_ target: Window) {
        let app = AXUIElementCreateApplication(target.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return }
        for window in windows where frame(of: window) == target.bounds {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }

    /// An Accessibility window's frame, top-left origin like the window list's.
    private static func frame(of window: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func onScreenWindows() -> [Window] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return Window(pid: pid, bounds: bounds, layer: layer)
        }
    }
}
