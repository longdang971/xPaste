import Foundation
import Combine
import AppKit

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

/// Which item's preview popover is on screen.
///
/// Outside `ContentView` for the same reason as `PanelSelection`, and it cost more here. As
/// `@State` there, `previewItemID` was read from `body` — the popover's binding is built inside
/// the card loop — so Space invalidated the entire panel, toolbar and every card body included,
/// *before* the popover was so much as created. The preview came up a whole re-layout after the
/// key press, which is the "it doesn't appear straight away" this object exists to remove. The
/// NSPopover handle was `@State` too, and assigning it from the `willShow` handler bought a
/// second full invalidation at the exact moment the popover was animating in.
///
/// Only `PreviewAnchor` observes this. `ContentView` reads it from callbacks, where the value is
/// always current, and never from `body`.
final class PanelPreview: ObservableObject {
    static let shared = PanelPreview()

    @Published private(set) var itemID: UUID?

    /// The live NSPopover behind the preview, held for one reason: closing it directly.
    ///
    /// Clearing `itemID` asks SwiftUI to dismiss it, and SwiftUI does that on its next pass —
    /// through a hosting view whose window is in the middle of being ordered out. When that pass
    /// does not land, the popover stays on screen with its parent gone: not key, no first
    /// responder, and its own close button running the same state change that already failed. So
    /// the panel closes it by hand as well.
    ///
    /// Not published: nothing reads it from a `body`.
    var popover: NSPopover?

    private init() {}

    /// Space, and the card menu's Preview entry. One press, one flip — see the key monitor in
    /// `AppDelegate` for why this is the only thing that decides.
    func toggle(_ id: UUID) {
        if itemID == id { close() } else { present(id) }
    }

    /// Switching straight from one card's preview to another leaves the old popover to the
    /// `willShow` handler, which closes whichever one is stale as the new one opens.
    func present(_ id: UUID) {
        guard itemID != id else { return }
        itemID = id
    }

    /// Both halves, in this order: the state change is what SwiftUI needs to agree the popover is
    /// gone, and the direct close is what guarantees it actually goes.
    func close() {
        if itemID != nil { itemID = nil }
        guard let live = popover else { return }
        popover = nil
        live.performClose(nil)
    }
}

/// Whether the filter sheet is up, and the NSPopover behind it.
///
/// Out of `ContentView` for the reason the preview is — `showFilters` was read from `body`, so
/// pressing the filter button rebuilt the whole panel before the sheet was created — and for one
/// more. SwiftUI writes `isPresented` back long after the popover has actually gone, and a click
/// landing in that gap made `toggle()` flip a still-true flag to false: the click that should have
/// reopened the sheet did nothing at all. Closing by hand rather than waiting to be told keeps the
/// flag and the screen in step, so every press of the button lands.
final class PanelFilters: ObservableObject {
    static let shared = PanelFilters()

    @Published private(set) var isPresented = false

    /// See `PanelPreview.popover`: held so the sheet can be taken off the screen directly.
    var popover: NSPopover?

    private init() {}

    func toggle() {
        if isPresented { close() } else { isPresented = true }
    }

    func close() {
        if isPresented { isPresented = false }
        guard let live = popover else { return }
        popover = nil
        live.performClose(nil)
    }
}

/// The filters the search query could become, and which of them Return would take.
///
/// Out of `ContentView` for the reason `PanelSelection` is — nothing in the panel's `body` reads
/// it — and out of the search field for a reason of its own: a SwiftUI view is not hit-tested
/// outside its parent's bounds, so a dropdown hung off the field as an overlay drew perfectly and
/// took no clicks at all (measured: not even `.onHover` fired over it). The rows are computed
/// where the query lives, in the field, and drawn by `SuggestionAnchor` at panel level, where the
/// container is big enough to contain them.
final class PanelSuggestions: ObservableObject {
    static let shared = PanelSuggestions()

    @Published private(set) var rows: [FilterSuggestion] = []
    /// Always a valid index into `rows` while there are any.
    @Published private(set) var highlighted = 0

    /// Applies a row. Set by the search field, which owns the query the row would replace; not
    /// published, because only a callback ever reads it.
    var take: ((FilterSuggestion) -> Void)?

    private init() {}

    func show(_ newRows: [FilterSuggestion]) {
        guard newRows != rows else { return }
        rows = newRows
        // The row that was under the highlight is rarely still in the list, let alone still in
        // that place, so a new list starts at the top.
        if highlighted != 0 { highlighted = 0 }
    }

    func clear() { show([]) }

    func move(by step: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(highlighted + step, 0), rows.count - 1)
        if next != highlighted { highlighted = next }
    }

    /// What Return takes, or nil when there is nothing to take.
    var current: FilterSuggestion? {
        guard highlighted < rows.count else { return rows.first }
        return rows[highlighted]
    }
}
