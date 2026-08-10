import AppKit

/// Which application a drag was released over.
///
/// The release point picks the *application*, not the insertion point inside it: the paste that
/// follows lands wherever that application's own caret or selection already is. Clicking at the
/// release point to move the caret first would destroy the selection the paste is meant to replace,
/// which is the whole reason this feature exists.
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
        windows.first { $0.layer == 0 && $0.pid != excluded && $0.bounds.contains(point) }?.pid
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
