import Foundation
import Combine

/// Which cards are selected in the panel.
///
/// Lives outside `ContentView` on purpose. As `@State` there, clicking a card invalidated the
/// entire panel — measured at 26–30ms of main-thread layout to repaint two card borders. Cards
/// observe this object through a small border view instead, so a selection change rebuilds only
/// those borders and leaves the toolbar, the scroll view and every card body untouched.
///
/// `ContentView` deliberately does NOT observe it: it reads `ids` inside callbacks (where the
/// value is always current) rather than in `body`.
final class PanelSelection: ObservableObject {
    static let shared = PanelSelection()

    @Published private(set) var ids: Set<UUID> = []

    /// Set by a card's tap handler so the ancestor tap gesture knows the click landed on a card
    /// and must not clear the selection. Not published — it is only ever read from callbacks.
    var suppressCardDeselect = false

    /// True between `.panelWillHide` and the next `.panelDidOpen`. Lives here rather than as
    /// `@State` on ContentView for the same reason as everything else in this object: nothing in
    /// `body` reads it, so owning it there bought nothing but a full-panel invalidation on every
    /// open and every close.
    var isHidingPanel = false

    private init() {}

    func set(_ newIDs: Set<UUID>) {
        guard newIDs != ids else { return }
        ids = newIDs
    }

    func select(_ id: UUID) { set([id]) }

    func toggle(_ id: UUID) {
        var next = ids
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        set(next)
    }

    func clear() { set([]) }

    /// What the selection should become once the visible row has changed underneath it.
    ///
    /// nil means leave it alone — something already selected is still on screen, and re-selecting
    /// would jerk the highlight back to the front of the row for no reason. A partly surviving
    /// multi-selection counts as alive: collapsing it to one card would quietly drop the rest of a
    /// batch the user had already lined up.
    ///
    /// Otherwise the row's first card, or an empty set when the row has no results at all.
    static func rebased(in items: [UUID], selected: Set<UUID>) -> Set<UUID>? {
        if items.contains(where: { selected.contains($0) }) { return nil }
        guard let first = items.first else { return [] }
        return [first]
    }

    /// What a click into the panel's empty space leaves selected.
    ///
    /// That click exists to drop a multi-selection back to a single card, so it keeps the topmost
    /// selected one — not the front of the row, which would move a highlight the user had put
    /// somewhere deliberately. It never leaves nothing: the row would sit unhighlighted and ⏎ /
    /// Backspace would do nothing until a card was clicked.
    static func collapsed(in items: [UUID], selected: Set<UUID>) -> Set<UUID> {
        if let primary = items.first(where: { selected.contains($0) }) { return [primary] }
        guard let first = items.first else { return [] }
        return [first]
    }

    /// Which card should hold the selection once `deleted` are gone from `items`.
    ///
    /// The first survivor at or after the deleted block — the card that slides into the gap — and
    /// failing that the last survivor before it, for a block that ran to the end of the row. nil
    /// only when nothing is left to select.
    ///
    /// Called before the delete, on the list as it stands: afterwards the deleted cards' positions
    /// are gone and there is no gap left to reason about.
    static func survivor(in items: [UUID], deleting deleted: Set<UUID>) -> UUID? {
        guard let firstGap = items.firstIndex(where: { deleted.contains($0) }) else { return nil }
        if let after = items[firstGap...].first(where: { !deleted.contains($0) }) { return after }
        return items[..<firstGap].last(where: { !deleted.contains($0) })
    }

    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}
