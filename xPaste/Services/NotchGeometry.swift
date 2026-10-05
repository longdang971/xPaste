import AppKit

/// Where the camera housing sits on a screen, and where a shape hanging from it goes.
///
/// Pure arithmetic on numbers `NSScreen` hands over, so the rules — what counts as a notch, where
/// a shape of a given size lands — are testable without a MacBook on the desk.
struct NotchGeometry: Equatable {
    /// The whole screen, in global screen coordinates.
    let screenFrame: NSRect
    /// The housing itself: the gap between the two strips of menu bar either side of it.
    let notchSize: CGSize
    /// Where the housing starts, measured from the screen's left edge.
    let notchMinX: CGFloat

    /// The housing on `screen`, or nil when it has none.
    ///
    /// `safeAreaInsets.top` is the test, not a model list: it is zero on an external display, on a
    /// Mac without a notch, and on a notched one set to a resolution that letterboxes the menu bar
    /// below the housing — and in that last case there is nothing around the housing to draw in.
    static func of(_ screen: NSScreen) -> NotchGeometry? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return nil
        }
        return make(screenFrame: screen.frame, topInset: screen.safeAreaInsets.top,
                    leftWidth: left.width, rightWidth: right.width)
    }

    static func make(screenFrame: NSRect, topInset: CGFloat,
                     leftWidth: CGFloat, rightWidth: CGFloat) -> NotchGeometry? {
        let width = screenFrame.width - leftWidth - rightWidth
        guard topInset > 0, width > 0 else { return nil }
        return NotchGeometry(screenFrame: screenFrame,
                             notchSize: CGSize(width: width, height: topInset),
                             notchMinX: leftWidth)
    }

    /// The housing's horizontal centre, in global coordinates.
    var midX: CGFloat { screenFrame.minX + notchMinX + notchSize.width / 2 }

    /// A rect of `size` hanging from the top of the screen, centred on the housing.
    ///
    /// Every state of the notch window uses this, so they all share one top edge and one centre:
    /// resizing the window from one to the next never moves what is drawn inside it.
    func frame(for size: CGSize) -> NSRect {
        NSRect(x: (midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// The housing as a rect in global coordinates.
    var notchRect: NSRect { frame(for: notchSize) }
}

extension NSScreen {
    /// Whether this screen has a camera housing cut into its menu bar.
    var hasNotch: Bool { NotchGeometry.of(self) != nil }
}
