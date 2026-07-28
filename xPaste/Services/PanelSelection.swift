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

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}
