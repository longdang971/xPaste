import AppKit

/// The rules a drag out of the panel follows.
///
/// A drag carries each item's own representation and the application it is released over decides
/// what to do with it — the ordinary macOS drag and drop. Kept apart from the AppKit session so the
/// rules are tested directly.
enum DragPaste {

    /// How far the pointer has to travel before a press becomes a drag rather than a click.
    static let threshold: CGFloat = 6

    struct Plan {
        let items: [ClipboardItem]
    }

    static func exceedsThreshold(from: NSPoint, to: NSPoint) -> Bool {
        abs(to.x - from.x) > threshold || abs(to.y - from.y) > threshold
    }

    /// Which cards a drag started on `dragged` carries.
    ///
    /// Dragging a card that is part of a multi-selection takes the whole selection, in the order the
    /// panel shows it — the order the cards happened to be clicked in is not an order anybody meant.
    static func plan(dragging dragged: ClipboardItem,
                     selection: Set<UUID>,
                     displayed: [ClipboardItem]) -> Plan {
        if selection.contains(dragged.id), selection.count > 1 {
            return Plan(items: displayed.filter { selection.contains($0.id) })
        }
        // A card can be deleted between the press and the drag passing the threshold.
        return Plan(items: displayed.contains(where: { $0.id == dragged.id }) ? [dragged] : [])
    }
}
