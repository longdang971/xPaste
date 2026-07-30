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

    func remove(_ id: UUID) {
        guard ids.contains(id) else { return }
        var next = ids
        next.remove(id)
        set(next)
    }

    func clear() { set([]) }

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

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}
