import SwiftUI
import AppKit

private enum ClipboardTab { case all, pinned }

struct ContentView: View {
    @EnvironmentObject private var store: ClipboardStore
    /// Read, never observed — see PanelSelection's note on why ContentView must not re-render
    /// when the selection moves.
    private var selection: PanelSelection { .shared }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("panelPosition") private var panelPosition: String = "bottom"
    @State private var copiedID: UUID?
    @State private var showClearConfirm = false
    @State private var showDeleteSelectedConfirm = false
    @State private var showSearch = false
    @State private var previewItemID: UUID?
    @State private var scrollTargetID: UUID?
    @State private var isHidingPanel = false
    @State private var pendingReorderID: UUID?
    @State private var activeTab: ClipboardTab = .all
    @State private var searchToggleTapped = false
    @FocusState private var searchFocused: Bool
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted
    @AppStorage("accessibilityBannerDismissed") private var accessibilityBannerDismissed = false
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var showAccessibilityBanner: Bool {
        !accessibilityTrusted && !accessibilityBannerDismissed
    }

    @ViewBuilder private var accessibilityCard: some View {
        AccessibilityPanelBanner(
            onEnable: {
                AccessibilityPermission.requestSystemPrompt()
                AccessibilityPermission.openSystemSettings()
            },
            onDismiss: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    accessibilityBannerDismissed = true
                }
            }
        )
    }

    private var isHorizontal: Bool {
        panelPosition == "bottom" || panelPosition == "top"
    }

    private var displayedItems: [ClipboardItem] {
        switch activeTab {
        case .all:
            return store.filteredItems
        case .pinned:
            let pinned = store.items.filter(\.isPinned)
            guard !store.searchQuery.isEmpty else { return pinned }
            return pinned.filter { $0.displayText.localizedCaseInsensitiveContains(store.searchQuery) }
        }
    }

    var body: some View {
        ZStack {
            PanelGlassBackground(cornerRadius: PanelLayout.cornerRadius)

            // Sheen falling from the top edge, on top of the glass. Light appearance needs a
            // stronger one to read as glare; dark appearance only wants a hint or it greys out.
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(colorScheme == .dark ? 0.06 : 0.20), location: 0),
                    .init(color: .white.opacity(colorScheme == .dark ? 0.01 : 0.05), location: 0.5),
                    .init(color: .white.opacity(0.0),  location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.12)
                if displayedItems.isEmpty {
                    if showAccessibilityBanner {
                        ScrollView(isHorizontal ? .horizontal : .vertical, showsIndicators: false) {
                            accessibilityCard.padding(16)
                        }
                    } else {
                        emptyState
                    }
                } else if isHorizontal {
                    horizontalList
                } else {
                    verticalList
                }

                Button("") {
                    // Gated inside the action rather than with `.disabled(selection.isEmpty)`:
                    // ContentView no longer re-renders on selection changes, so a disabled-state
                    // read in `body` would go stale the moment the selection moved.
                    guard !selection.isEmpty else { return }
                    if selection.count > 1 {
                        showDeleteSelectedConfirm = true
                    } else {
                        store.deleteItems(ids: selection.ids)
                        selection.clear()
                    }
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(searchFocused)
                .opacity(0)
                .frame(width: 0, height: 0)

                Button("") {
                    selection.set(Set(displayedItems.map(\.id)))
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(searchFocused)
                .opacity(0)
                .frame(width: 0, height: 0)

                // Arrow-key navigation between cards. Left/Up move to the previous item,
                // Right/Down to the next — so it feels natural whether the panel lays the
                // cards out horizontally (bottom/top) or vertically (left/right).
                Group {
                    Button("") { moveSelection(by: -1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { moveSelection(by: 1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { moveSelection(by: -1) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { moveSelection(by: 1) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                }
                .disabled(searchFocused)
                .opacity(0)
                .frame(width: 0, height: 0)

                Group {
                    Button("") { if let it = primarySelectedItem { pasteItem(it) } }
                        .keyboardShortcut(.return, modifiers: [])
                    Button("") { if let it = primarySelectedItem { pastePlainText(it) } }
                        .keyboardShortcut(.return, modifiers: .shift)
                    Button("") { if let it = primarySelectedItem { copyItem(it) } }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("") { if let it = primarySelectedItem { togglePreview(it) } }
                        .keyboardShortcut(.space, modifiers: [])
                }
                .disabled(searchFocused)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.55), location: 0),
                            .init(color: .white.opacity(0.15), location: 0.25),
                            .init(color: .white.opacity(0.05), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 32, x: 0, y: -8)
        .shadow(color: .black.opacity(0.10), radius:  6, x: 0, y: -2)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            // This ancestor gesture fires BEFORE a tapped card's own .onTapGesture (confirmed via
            // logging), so `suppressCardDeselect` isn't set yet at this instant. Defer the decision
            // to the next runloop tick: by then selectItem() has run and set the flag, so a click
            // that landed on a card won't collapse the search or clear the selection. A click on
            // empty space leaves the flag false and still dismisses search / deselects as before.
            DispatchQueue.main.async {
                if selection.suppressCardDeselect {
                    selection.suppressCardDeselect = false
                    return
                }
                // Tapping the search icon / a compact tab sets this for ~0.3s and opens the search
                // before `searchFocused` flips true. Without this guard the deferred close below
                // would immediately dismiss the search the toggle just opened.
                if searchToggleTapped { return }
                if showSearch, !searchFocused {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showSearch = false
                        store.searchQuery = ""
                    }
                }
                if !NSEvent.modifierFlags.contains(.command) {
                    selection.clear()
                }
            }
        })
        .onChange(of: showSearch) { open in
            // When the search box closes by any path, force the TextField to resign — otherwise it
            // stays first responder while hidden, so the caret keeps blinking there and keystrokes
            // still land in an invisible field. Then restore a live selection (first item if none),
            // but never while the panel is hiding: that path intentionally clears the selection.
            guard !open else { return }
            searchFocused = false
            guard !isHidingPanel else { return }
            if selection.isEmpty, let first = displayedItems.first {
                selection.select(first.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelWillHide)) { _ in
            // Only mutate when there is actually something to reset. `store.searchQuery` is
            // @Published and emits even when set to the same value, which would invalidate the
            // whole ContentView and force a ~110ms synchronous re-layout right as the close
            // animation starts — freezing the slide. Guarding keeps the close smooth.
            isHidingPanel = true
            if showSearch { showSearch = false }
            if !store.searchQuery.isEmpty { store.searchQuery = "" }
            selection.clear()
            if previewItemID != nil { previewItemID = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pasteNumberedItem)) { note in
            guard let number = note.userInfo?["number"] as? Int,
                  let item = item(numbered: number) else { return }
            if note.userInfo?["plainText"] as? Bool == true {
                pastePlainText(item)
            } else {
                pasteItem(item)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidHide)) { _ in
            // Run the deferred history reorder off-screen. Delay it past the paste keystroke so
            // the re-layout it triggers can never stall the ⌘V that fires ~20ms after hide.
            guard let id = pendingReorderID else { return }
            pendingReorderID = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if let item = store.items.first(where: { $0.id == id }) {
                    store.moveToTop(item)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidOpen)) { _ in
            isHidingPanel = false
            // `AXIsProcessTrusted()` is a synchronous IPC round-trip; running it here put it in
            // the window between the hotkey and the panel starting to slide. The 2s timer below
            // polls the same value, so the banner still appears within a blink of being granted.
            DispatchQueue.main.async {
                let trusted = AccessibilityPermission.isTrusted
                if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
            }
            // Auto-select the first item on open so the keyboard is live immediately:
            // ⌘A selects all, ←/→ move between cards, ⏎ pastes — no click into the list needed.
            if let first = displayedItems.first {
                selection.select(first.id)
            }
        }
        .onReceive(permissionTimer) { _ in
            let trusted = AccessibilityPermission.isTrusted
            if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        }
        .confirmationDialog(
            "Delete all unpinned clipboard history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clearUnpinned() }
        }
        .onChange(of: showDeleteSelectedConfirm) { showing in
            NotificationCenter.default.post(
                name: showing ? .clipboardAlertShown : .clipboardAlertHidden,
                object: nil
            )
        }
        .alert(
            "Delete \(selection.count) selected item\(selection.count == 1 ? "" : "s")?",
            isPresented: $showDeleteSelectedConfirm
        ) {
            Button("Delete", role: .destructive) {
                store.deleteItems(ids: selection.ids)
                selection.clear()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
        .environment(\.panelScale, panelScale)
    }

    /// Uniform card scale for the screen the panel currently sits on, so cards stay
    /// proportional to the adaptively-sized bar. Sourced from the store (set by AppDelegate
    /// from the same screen it frames the panel with) so it's observable and never disagrees
    /// with the bar — reading NSScreen.main here could see a different display.
    private var panelScale: CGFloat {
        store.panelScale
    }

    private let toolbarSpring = Animation.spring(response: 0.3, dampingFraction: 0.9)

    private var toolbar: some View {
        ZStack {
            HStack(spacing: 6) {
                Spacer(minLength: 0)

                SearchIconButton {
                    searchToggleTapped = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchToggleTapped = false }
                    withAnimation(toolbarSpring) { showSearch = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
                }

                tabFull(title: "Clipboard", icon: "clock.arrow.circlepath", tab: .all)
                tabFull(title: "Pin", icon: "pin.fill", iconColor: .red, tab: .pinned)

                Spacer(minLength: 0)
            }
            .opacity(showSearch ? 0 : 1)
            .allowsHitTesting(!showSearch)
            .overlay(alignment: .trailing) {
                MoreMenu { showClearConfirm = true }
                    .opacity(showSearch ? 0 : 1)
                    .allowsHitTesting(!showSearch)
            }

            HStack(spacing: 8) {
                expandedSearchBar
                tabCompact(icon: "clock.arrow.circlepath", tab: .all)
                tabCompact(icon: "pin.fill", iconColor: .red, tab: .pinned)
            }
            .frame(maxWidth: 540)
            .opacity(showSearch ? 1 : 0)
            .scaleEffect(x: showSearch ? 1 : 0.5, anchor: .center)
            .allowsHitTesting(showSearch)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .contentShape(Rectangle())
        .onTapGesture {
            guard showSearch else { return }
            withAnimation(toolbarSpring) { showSearch = false; store.searchQuery = "" }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func tabFull(title: String, icon: String, iconColor: Color? = nil, tab: ClipboardTab) -> some View {
        FullTabButton(title: title, icon: icon, iconColor: iconColor, isSelected: activeTab == tab) {
            activeTab = tab
        }
    }

    private func tabCompact(icon: String, iconColor: Color? = nil, tab: ClipboardTab) -> some View {
        CompactTabButton(icon: icon, iconColor: iconColor, isSelected: activeTab == tab) {
            searchToggleTapped = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchToggleTapped = false }
            activeTab = tab
        }
    }

    private var expandedSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            DebouncedSearchField(focused: $searchFocused) {
                guard !searchToggleTapped else { return }
                withAnimation(toolbarSpring) { showSearch = false }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            Capsule()
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .overlay(Capsule().stroke(Color.accentColor, lineWidth: 2))
        )
    }

    private var horizontalList: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1).id("h-list-start")
                    LazyHStack(spacing: PanelLayout.cardSpacing) {
                        if showAccessibilityBanner {
                            accessibilityCard
                        }
                        ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemCard(
                                item: item, index: index + 1, isCopied: copiedID == item.id
                            )
                            .overlay(PanelClickOverlay(notification: .cmdClickInPanel) { toggleSelection(item.id) })
                            .overlay(PanelClickOverlay(notification: .doubleClickInPanel) { pasteItem(item) })
                            .onTapGesture(count: 1) { selectItem(item) }
                            .overlay(CardContextMenu { cardMenu(for: item) })
                            .popover(isPresented: previewBinding(for: item), arrowEdge: previewArrowEdge) {
                                PreviewPopoverContent(item: item) { previewItemID = nil }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, PanelLayout.listTopPadding)
                    .padding(.bottom, PanelLayout.listBottomPadding)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .panelDidOpen)) { _ in
                proxy.scrollTo("h-list-start", anchor: .leading)
            }
            .onChange(of: scrollTargetID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var verticalList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: PanelLayout.cardSpacing) {
                    if showAccessibilityBanner {
                        accessibilityCard
                    }
                    ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                        ClipboardItemCard(
                            item: item, index: index + 1, isCopied: copiedID == item.id
                        )
                        .frame(maxWidth: .infinity)
                        .overlay(PanelClickOverlay(notification: .cmdClickInPanel) { toggleSelection(item.id) })
                        .overlay(PanelClickOverlay(notification: .doubleClickInPanel) { pasteItem(item) })
                        .onTapGesture(count: 1) { selectItem(item) }
                        .overlay(CardContextMenu { cardMenu(for: item) })
                        .popover(isPresented: previewBinding(for: item), arrowEdge: previewArrowEdge) {
                            PreviewPopoverContent(item: item) { previewItemID = nil }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            .onReceive(NotificationCenter.default.publisher(for: .panelDidOpen)) { _ in
                if let first = displayedItems.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .onChange(of: scrollTargetID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: activeTab == .pinned ? "pin" : "doc.on.clipboard")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            Text(activeTab == .pinned ? "No pinned items" : (store.searchQuery.isEmpty ? "Nothing copied yet" : "No results"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var targetSuffix: String {
        if let app = store.targetAppName, !app.isEmpty { return " to \(app)" }
        return ""
    }

    /// The card's right-click menu, built only when AppKit asks for it.
    ///
    /// This used to be a SwiftUI `.contextMenu`, whose content SwiftUI evaluates eagerly for
    /// every row: one scroll built 86 menus for 43 cards, each ten Buttons carrying a
    /// `.keyboardShortcut`. It dominated scrolling jank — 45 late frames with it, 8 without.
    private func cardMenu(for item: ClipboardItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Paste\(targetSuffix)", symbol: "arrow.right.doc.on.clipboard",
                                     key: "\r") { pasteItem(item) })
        if item.text != nil {
            menu.addItem(ClosureMenuItem(title: "Paste as Plain Text", symbol: "text.alignleft",
                                         key: "\r", modifiers: .shift) { pastePlainText(item) })
        }
        menu.addItem(ClosureMenuItem(title: "Copy", symbol: "doc.on.doc",
                                     key: "c", modifiers: .command) { copyItem(item) })
        menu.addItem(.separator())
        if item.type == .url, let text = item.text, let url = URL(string: text) {
            menu.addItem(ClosureMenuItem(title: "Open URL", symbol: "safari") {
                NSWorkspace.shared.open(url)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Delete", symbol: "trash",
                                     key: "\u{8}") { store.delete(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: item.isPinned ? "Unpin" : "Pin",
                                     symbol: item.isPinned ? "pin.slash" : "pin") { store.togglePin(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Preview", symbol: "eye", key: " ") { previewItemID = item.id })
        menu.addItem(ClosureMenuItem(title: "Share", symbol: "square.and.arrow.up") {
            presentShareMenu(for: item)
        })
        return menu
    }

    /// Presents the system share picker on demand. Previously the share services were built as a
    /// SwiftUI submenu, which made `.contextMenu` eagerly call `NSSharingService.sharingServices`
    /// for every visible card on every re-layout (~110ms) — freezing selection/paste. Computing
    /// them only when Share is chosen keeps the context menu (and thus every click) cheap.
    private func presentShareMenu(for item: ClipboardItem) {
        let items = shareItems(for: item)
        guard !items.isEmpty else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView else { return }
            let loc = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            NSSharingServicePicker(items: items)
                .show(relativeTo: NSRect(origin: loc, size: .zero), of: view, preferredEdge: .minY)
        }
    }

    private func shareItems(for item: ClipboardItem) -> [Any] {
        switch item.type {
        case .url:
            if let text = item.text, let url = URL(string: text) { return [url] }
            return [item.displayText]
        case .text:
            return [item.text ?? item.displayText]
        case .image:
            let data = item.imageData
                ?? ClipboardStore.shared.imageURL(for: item.id).flatMap { try? Data(contentsOf: $0) }
            if let data, let img = NSImage(data: data) { return [img] }
            return [item.displayText]
        case .file, .folder:
            return item.fileURLs ?? []
        }
    }

    private func copyItem(_ item: ClipboardItem) {
        item.copyToPasteboard()
        withAnimation(.spring(response: 0.3)) {
            store.moveToTop(item)
            copiedID = item.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation { copiedID = nil }
        }
    }

    private func pasteItem(_ item: ClipboardItem) {
        // When "Always paste as Plain Text" is on, route text-bearing items through the
        // plain-text path so they're pasted unformatted.
        if UserDefaults.standard.bool(forKey: "alwaysPastePlainText"), item.text != nil {
            pastePlainText(item)
            return
        }
        item.copyToPasteboard()
        // Defer the history reorder until the panel is hidden — moveToTop mutates the
        // @Published store, which would force a ~120ms re-layout and freeze the close animation.
        pendingReorderID = item.id
        NotificationCenter.default.post(name: .pasteClipboardItem, object: nil)
    }

    private func pastePlainText(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text ?? item.displayText, forType: .string)
        // Tell the monitor this clipboard change is ours; otherwise it re-captures the pasted
        // text with the target app as the source and overwrites the item's real source app.
        ClipboardMonitor.shared.markNextChangeAsOwn()
        pendingReorderID = item.id
        NotificationCenter.default.post(name: .pasteClipboardItem, object: nil)
    }

    private func toggleSelection(_ id: UUID) {
        selection.toggle(id)
    }

    /// The card showing `number` in its footer — the same 1-based index handed to the cards.
    private func item(numbered number: Int) -> ClipboardItem? {
        let items = displayedItems
        guard number >= 1, number <= items.count else { return nil }
        return items[number - 1]
    }

    private var primarySelectedItem: ClipboardItem? {
        displayedItems.first { selection.contains($0.id) }
    }

    private var previewArrowEdge: Edge {
        switch panelPosition {
        case "top":   return .bottom
        case "left":  return .trailing
        case "right": return .leading
        default:      return .top
        }
    }

    private func previewBinding(for item: ClipboardItem) -> Binding<Bool> {
        Binding(
            get: { previewItemID == item.id },
            set: { show in if !show { previewItemID = nil } }
        )
    }

    private func togglePreview(_ item: ClipboardItem) {
        previewItemID = (previewItemID == item.id) ? nil : item.id
    }

    private func selectItem(_ item: ClipboardItem) {
        selection.suppressCardDeselect = true
        selection.select(item.id)
    }

    /// Moves the single-item selection by `delta` in display order (clamped to the ends) and
    /// asks the list to scroll the newly selected card into view. With nothing selected yet,
    /// the first arrow press lands on an end so navigation can start from a clean state.
    private func moveSelection(by delta: Int) {
        let ids = displayedItems.map(\.id)
        guard !ids.isEmpty else { return }
        let newIndex: Int
        if let current = ids.firstIndex(where: { selection.contains($0) }) {
            newIndex = min(max(current + delta, 0), ids.count - 1)
        } else {
            newIndex = delta > 0 ? 0 : ids.count - 1
        }
        let target = ids[newIndex]
        // No `suppressCardDeselect` here: that flag only exists to stop the ancestor tap
        // handler from clearing a selection made by a card *click*. Arrow-key navigation
        // produces no tap, so leaving it set would swallow the user's next empty-space click.
        selection.select(target)
        scrollTargetID = target
    }
}

private struct AccessibilityPanelBanner: View {
    var onEnable: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "accessibility")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 14)

            Text("Enable Accessibility")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Allow xPaste to paste into other apps.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            Spacer(minLength: 14)

            Button(action: onEnable) {
                Text("Enable")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 220, height: PanelLayout.cardBaseHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}

private struct SearchIconButton: View {
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 20, weight: .medium))
            .foregroundColor(.secondary)
            .padding(7)
            .background(Capsule().fill(hovered ? Color(NSColor.controlColor) : .clear))
            .onHover { hovered = $0 }
            .onTapGesture { onTap() }
    }
}

private struct MoreMenu: View {
    let onClearHistory: () -> Void
    @State private var hovered = false

    var body: some View {
        Menu {
            Button(role: .destructive, action: onClearHistory) {
                Label("Clear History", systemImage: "trash")
            }
            Divider()
            Button {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Quit xPaste", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(7)
                .background(Capsule().fill(hovered ? Color(NSColor.controlColor) : .clear))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
    }
}

private struct FullTabButton: View {
    let title: String
    let icon: String
    let iconColor: Color?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(iconColor ?? (isSelected ? Color(NSColor.labelColor) : .secondary))
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? Color(NSColor.labelColor) : .secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(
                isSelected ? Color(NSColor.controlColor) :
                hovered ? Color(NSColor.controlColor).opacity(0.6) : .clear
            ))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct CompactTabButton: View {
    let icon: String
    let iconColor: Color?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(iconColor.map { $0.opacity(isSelected ? 1 : 0.45) }
                                 ?? (isSelected ? Color(NSColor.labelColor) : .secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(
                    isSelected ? Color(NSColor.controlColor) :
                    hovered ? Color(NSColor.controlColor).opacity(0.6) : .clear
                ))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct PanelClickOverlay: NSViewRepresentable {
    let notification: Notification.Name
    let action: () -> Void

    func makeNSView(context: Context) -> PanelClickView {
        PanelClickView(notification: notification, action: action)
    }

    func updateNSView(_ nsView: PanelClickView, context: Context) {
        nsView.action = action
    }
}

private final class PanelClickView: NSView {
    let notification: Notification.Name
    var action: () -> Void
    private var observer: NSObjectProtocol?

    init(notification: Notification.Name, action: @escaping () -> Void) {
        self.notification = notification
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let obs = observer { NotificationCenter.default.removeObserver(obs) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let loc = note.userInfo?["locationInWindow"] as? NSPoint
                else { return }
                let pt = self.convert(loc, from: nil)
                guard self.bounds.contains(pt) else { return }
                self.action()
            }
        } else {
            if let obs = observer { NotificationCenter.default.removeObserver(obs); observer = nil }
        }
    }
}

/// The search text field, with its own local text state.
///
/// Bound straight to `store.searchQuery` this used to cost a full-panel re-layout on every
/// keystroke — 23–52ms measured, because `searchQuery` is `@Published` and ContentView observes
/// the store. Typing now only rebuilds this small view; the query reaches the store once the
/// user pauses, so a burst of keystrokes re-filters and re-lays out the card list a single time.
private struct DebouncedSearchField: View {
    @EnvironmentObject private var store: ClipboardStore
    @FocusState.Binding var focused: Bool
    /// Called when the field loses focus while empty, so the toolbar can collapse the search.
    let onEmptyBlur: () -> Void

    @State private var text = ""
    @State private var debounce: Task<Void, Never>?

    private static let debounceNanos: UInt64 = 80_000_000

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    // Shown whenever the field is empty, focused or not: the search box opens
                    // already focused, so gating on !focused hid it exactly when it was
                    // the only thing telling you what the empty box was for.
                    if text.isEmpty {
                        Text("Search...")
                            .font(.system(size: 15))
                            .foregroundColor(Color(NSColor.placeholderTextColor))
                            .allowsHitTesting(false)
                    }
                }

            if !text.isEmpty {
                Button { apply("", immediately: true) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: text) { new in
            debounce?.cancel()
            debounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.debounceNanos)
                guard !Task.isCancelled else { return }
                push(new)
            }
        }
        .onChange(of: focused) { isFocused in
            // Losing focus with a live query means the user clicked into the results (e.g. to
            // double-click-paste). Keep the search open so the filtered list stays put and the
            // paste hits the right item. Only auto-close when nothing was typed.
            guard !isFocused, text.isEmpty else { return }
            onEmptyBlur()
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelWillHide)) { _ in
            debounce?.cancel()
            if !text.isEmpty { text = "" }
        }
        .onDisappear { debounce?.cancel() }
    }

    private func apply(_ new: String, immediately: Bool) {
        text = new
        if immediately {
            debounce?.cancel()
            push(new)
        }
    }

    private func push(_ new: String) {
        if store.searchQuery != new { store.searchQuery = new }
    }
}

/// An `NSMenuItem` that runs a closure, so menus can be assembled inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, symbol: String? = nil, key: String = "",
         modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// Hosts a card's right-click menu without SwiftUI ever building it up front.
private struct CardContextMenu: NSViewRepresentable {
    let build: () -> NSMenu

    func makeNSView(context: Context) -> CardContextMenuView { CardContextMenuView(build: build) }
    func updateNSView(_ nsView: CardContextMenuView, context: Context) { nsView.build = build }
}

private final class CardContextMenuView: NSView {
    var build: () -> NSMenu

    init(build: @escaping () -> NSMenu) {
        self.build = build
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Claim right-clicks (and ⌃-click) only, so the card's own tap, double-click and ⌘-click
    /// handling underneath is untouched.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp:
            return super.hitTest(point)
        case .leftMouseDown where event.modifierFlags.contains(.control):
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { build() }
}
