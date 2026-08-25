import AppKit

/// The rules a drag out of the panel follows.
///
/// All of it is decisions — which cards travel, under what payload, what ends up on the pasteboard —
/// with no AppKit session anywhere near it, so every rule here is tested directly.
enum DragPaste {

    /// The only type a deferred paste puts on the dragging pasteboard.
    ///
    /// Deliberately private to xPaste and declared nowhere else: no application registers it, so no
    /// application accepts the drop, so nothing is inserted anywhere and the release is free to mean
    /// "paste this here" instead. That is the whole mechanism — a drop cannot replace a selection or
    /// leave what it inserted selected, and a paste can.
    static let deferredType = NSPasteboard.PasteboardType("com.user.xPaste.deferred-paste")

    /// How far the pointer has to travel before a press becomes a drag rather than a click.
    static let threshold: CGFloat = 6

    enum PayloadKind {
        /// Nothing droppable: the release triggers a real paste.
        case deferredPaste
        /// The item's own representation, so a drop into Finder or a web upload zone still works.
        case native
    }

    struct Plan {
        let items: [ClipboardItem]
        let kind: PayloadKind
    }

    /// What to put on the pasteboard once the drag has ended.
    enum PasteContent: Equatable {
        /// The item itself, keeping any formatting it captured.
        case item(ClipboardItem)
        /// This exact string, unformatted.
        case plain(String)

        /// `ClipboardItem` is not `Equatable` and does not need to be: two of them are the same item
        /// here when they are the same item.
        static func == (a: PasteContent, b: PasteContent) -> Bool {
            switch (a, b) {
            case let (.item(x), .item(y)):   return x.id == y.id
            case let (.plain(x), .plain(y)): return x == y
            default:                         return false
            }
        }
    }

    static func exceedsThreshold(from: NSPoint, to: NSPoint) -> Bool {
        abs(to.x - from.x) > threshold || abs(to.y - from.y) > threshold
    }

    /// Which cards a drag started on `dragged` carries, and under which payload.
    ///
    /// Dragging a card that is part of a multi-selection takes the whole selection, in the order the
    /// panel shows it — the order the cards happened to be clicked in is not an order anybody meant.
    static func plan(dragging dragged: ClipboardItem,
                     selection: Set<UUID>,
                     displayed: [ClipboardItem],
                     accessibilityTrusted: Bool) -> Plan {
        let items: [ClipboardItem]
        if selection.contains(dragged.id), selection.count > 1 {
            items = displayed.filter { selection.contains($0.id) }
        } else {
            // A card can be deleted between the press and the drag passing the threshold.
            items = displayed.contains(where: { $0.id == dragged.id }) ? [dragged] : []
        }
        return Plan(items: items, kind: kind(for: items, accessibilityTrusted: accessibilityTrusted))
    }

    private static func kind(for items: [ClipboardItem], accessibilityTrusted: Bool) -> PayloadKind {
        // Without Accessibility there is no way to press ⌘V, so a deferred paste could never be
        // delivered — the real payload at least keeps dragging working as it always did.
        guard accessibilityTrusted else { return .native }
        let allText = !items.isEmpty
            && items.allSatisfy { $0.type == .text || $0.type == .url || $0.type == .color }
        return allText ? .deferredPaste : .native
    }

    /// What the release should write to the pasteboard, or nil when there is nothing to write.
    static func content(for plan: Plan, shiftHeld: Bool, alwaysPlainText: Bool,
                        separator: MultiPaste.Separator) -> PasteContent? {
        guard let first = plan.items.first else { return nil }
        if plan.items.count > 1 {
            // A group is always plain: there is no one piece of formatting spanning several
            // unrelated captures. `joinedText` returns nil when fewer than two of them have any
            // text to contribute — two unnamed images, say — and then the first item is the best
            // that can be done, picture and all.
            if let joined = MultiPaste.joinedText(for: plan.items.map(ClipboardStore.shared.hydrated),
                                                  separator: separator) {
                return .plain(joined)
            }
            return .item(first)
        }
        if shiftHeld || alwaysPlainText, let text = first.text {
            return .plain(text)
        }
        return .item(first)
    }

    /// Puts what the release decided on the pasteboard, and claims the change as xPaste's own.
    ///
    /// Claiming goes through the monitor rather than being written out here, because it has to
    /// happen *after* the write — see `ClipboardMonitor.writeOwned`. Done the other way round, the
    /// monitor picked the pasted text straight back up as a fresh copy: filed under the
    /// application the card had just been dropped into, and, since that capture replaces the item
    /// it matches, taking the original's name with it.
    static func deliver(_ content: PasteContent, using monitor: ClipboardMonitor = .shared) {
        monitor.writeOwned { pb in
            switch content {
            case let .item(item):
                item.write(to: pb)
            case let .plain(text):
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }

    /// How many UTF-16 units the paste will insert, or nil when what lands is not text and so has no
    /// range to select. UTF-16 because that is the unit Accessibility text ranges are measured in;
    /// counting characters would select too little of anything outside the basic plane.
    static func selectableLength(of content: PasteContent) -> Int? {
        switch content {
        case let .plain(text):
            return text.utf16.count
        case let .item(item):
            // What actually lands, not what the card shows: this length is the range the paste
            // then re-selects through Accessibility, and measuring the prefix would leave the
            // selection short of the text it just inserted.
            guard item.type == .text || item.type == .url || item.type == .color,
                  let text = ClipboardStore.shared.fullText(for: item) else { return nil }
            return text.utf16.count
        }
    }
}
