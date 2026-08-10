import AppKit
import ApplicationServices

/// Leaves the text a paste just inserted selected, so it can be typed straight over.
///
/// A paste puts the caret at the end of what it inserted, and that is all there is to work from: walk
/// back from there by as much as was written.
///
/// Everything here fails quietly. Whether an application exposes a writable selection over
/// Accessibility is entirely up to it — native text views do, browsers and Electron apps often do
/// not — and a drag that pasted correctly must not report an error because the highlight could not be
/// applied afterwards.
enum AXTextSelection {

    /// The range covering an insertion of `length` that finished with the caret at `caret`.
    ///
    /// Clamped to the start of the text: the caret can legitimately sit earlier than the insertion
    /// was long, if the target normalised the text or took only part of it, and a negative location
    /// would either be rejected or — worse — accepted as something enormous.
    static func rangeCoveringInsertion(caretAt caret: Int, length: Int) -> CFRange {
        let selectable = max(0, min(length, caret))
        return CFRange(location: caret - selectable, length: selectable)
    }

    /// Selects the last `length` UTF-16 units before the caret in `pid`'s focused text element.
    static func selectPastedText(pid: pid_t, length: Int) {
        guard length > 0 else { return }
        let app = AXUIElementCreateApplication(pid)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return }
        let target = element as! AXUIElement

        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXSelectedTextRangeAttribute as CFString,
                                            &current) == .success,
              let value = current, CFGetTypeID(value) == AXValueGetTypeID()
        else { return }

        var caretRange = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &caretRange) else { return }

        var wanted = rangeCoveringInsertion(caretAt: caretRange.location, length: length)
        guard wanted.length > 0, let newValue = AXValueCreate(.cfRange, &wanted) else { return }
        AXUIElementSetAttributeValue(target, kAXSelectedTextRangeAttribute as CFString, newValue)
    }
}
