import SwiftUI
import AppKit
import Combine

private enum ClipboardTab { case all, pinned }

struct ContentView: View {
    @EnvironmentObject private var store: ClipboardStore
    /// Read, never observed — see PanelSelection's note on why ContentView must not re-render
    /// when the selection moves.
    private var selection: PanelSelection { .shared }
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("panelPosition") private var panelPosition: String = "bottom"
    @State private var showSearch = false
    /// What the list was last asked to scroll to. See `PanelScrollRequest` for why it is not
    /// simply the card's id.
    @State private var scrollRequest: PanelScrollRequest?
    @State private var pendingReorderID: UUID?
    @State private var activeTab: ClipboardTab = .all
    @State private var searchToggleTapped = false
    /// The card whose header title is currently being edited, if any.
    @State private var renameItemID: UUID?
    /// Mirrors the `.clipboardAlertShown` / `.clipboardAlertHidden` handshake that `AppDelegate`
    /// uses to stop swallowing Escape and ⌘S — posted while an item is being edited in the preview
    /// popover, while the delete confirmation is up, and (by this view itself) while renaming. The
    /// card-level ⌘A below needs the same protection: it must stand down whenever any of those is
    /// live, or it claims ⌘A out from under whichever text field actually has focus.
    @State private var alertPresented = false
    /// The filter sheet's state lives in `PanelFilters` for the same reasons the preview's does.
    private var filterSheet: PanelFilters { .shared }
    /// Which card's preview is up, and the NSPopover behind it, both live in `PanelPreview` —
    /// see there for what owning them here cost. Read from callbacks only, never from `body`.
    private var preview: PanelPreview { .shared }
    @FocusState private var searchFocused: Bool
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted
    @AppStorage("accessibilityBannerDismissed") private var accessibilityBannerDismissed = false
    /// Whether the app is registered to start at login — the "Run in Background" notice's only
    /// reason to exist. Read once when the panel opens, and again right after Enable is pressed.
    @State private var launchesAtLogin = LoginItem.isEnabled
    @AppStorage("runInBackgroundBannerDismissed") private var runInBackgroundBannerDismissed = false
    /// Polls for the Accessibility grant while the banner could still change.
    ///
    /// Started when the panel opens and stopped when it hides — and stopped for good the moment
    /// permission is granted, because there is nothing left to detect. It used to be an
    /// `.autoconnect()` publisher held for the app's whole life: a main-thread wake-up every two
    /// seconds, forever, in an app whose entire design is about not paying for work nobody is
    /// waiting on. It kept firing with the panel hidden, and kept firing long after the answer
    /// had stopped being able to change.
    @State private var permissionPoll: AnyCancellable?

    private var showAccessibilityBanner: Bool {
        !accessibilityTrusted && !accessibilityBannerDismissed
    }

    private var showRunInBackgroundBanner: Bool {
        !launchesAtLogin && !runInBackgroundBannerDismissed
    }

    /// True while either notice card is in the row — the empty history still has cards to show.
    private var showNoticeCards: Bool {
        showAccessibilityBanner || showRunInBackgroundBanner
    }

    /// The notice cards, in the order Paste shows them: whatever stops the app working at all
    /// first, then the one that only makes it more reliable.
    @ViewBuilder private var noticeCards: some View {
        if showAccessibilityBanner {
            PanelNoticeCard(
                symbol: "accessibility",
                title: "Enable Accessibility",
                message: "Allow xPaste to paste into other apps.",
                actionTitle: "Enable",
                onAction: {
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
        if showRunInBackgroundBanner {
            PanelNoticeCard(
                symbol: "waveform.path.ecg",
                title: "Run in Background",
                message: "Ensure xPaste is always running.",
                actionTitle: "Enable",
                onAction: {
                    LoginItem.enable()
                    // `register()` is synchronous, but the status it reports lags it by a beat.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            launchesAtLogin = LoginItem.isEnabled
                        }
                    }
                },
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        runInBackgroundBannerDismissed = true
                    }
                }
            )
        }
    }

    private var isHorizontal: Bool {
        panelPosition == "bottom" || panelPosition == "top"
    }

    private var displayedItems: [ClipboardItem] {
        switch activeTab {
        case .all:
            return store.filteredItems
        case .pinned:
            // Narrowed by the very same search box and filter popover as the main tab — one that
            // understood them in one tab and not the other would just look broken.
            return store.pinnedFilteredItems
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
                // Above the list: the search field's suggestion dropdown hangs down over the
                // first row of cards, and a later sibling would draw straight over it.
                toolbar.zIndex(1)
                Divider().opacity(0.12)
                if displayedItems.isEmpty {
                    if showNoticeCards {
                        ScrollView(isHorizontal ? .horizontal : .vertical, showsIndicators: false) {
                            if isHorizontal {
                                HStack(spacing: PanelLayout.cardSpacing) { noticeCards }
                                    .padding(16)
                            } else {
                                VStack(spacing: PanelLayout.cardSpacing) { noticeCards }
                                    .padding(16)
                            }
                        }
                    } else {
                        emptyState
                    }
                } else if isHorizontal {
                    horizontalList
                } else {
                    verticalList
                }

                // ⌫ and ⌘⌫ both delete the selection — the second because every Mac list that
                // deletes with one deletes with the other, and reaching for ⌫ alone after a
                // ⌘-click multi-selection means letting go of ⌘ first.
                Group {
                    Button("") { deleteSelection() }
                        .keyboardShortcut(.delete, modifiers: [])
                    Button("") { deleteSelection() }
                        .keyboardShortcut(.delete, modifiers: .command)
                }
                .disabled(searchFocused || isRenaming)
                .opacity(0)
                .frame(width: 0, height: 0)

                Button("") {
                    selection.set(Set(displayedItems.map(\.id)))
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(searchFocused || isRenaming || alertPresented)
                .opacity(0)
                .frame(width: 0, height: 0)

                // Arrow-key navigation between cards lives in `AppDelegate`'s key monitor, not
                // here — see `PanelArrowKey` for the two ways four hidden key equivalents guarded
                // by `.disabled(searchFocused …)` went silently dead. It arrives as
                // `.moveSelectionBy` below.

                Group {
                    // ⏎ pastes what is selected — all of it. Pasting only the first of three
                    // ⌘-clicked cards is never what the selection meant, and one shortcut for
                    // both cases means one fewer hidden button on the panel's open path (each
                    // registered key equivalent is resolved when first responder is established).
                    Button("") { pasteSelected() }
                        .keyboardShortcut(.return, modifiers: [])
                    Button("") { if let it = primarySelectedItem { pastePlainText(it) } }
                        .keyboardShortcut(.return, modifiers: .shift)
                    Button("") { if let it = primarySelectedItem { copyItem(it) } }
                        .keyboardShortcut("c", modifiers: .command)
                }
                .disabled(searchFocused || isRenaming)
                .opacity(0)
                .frame(width: 0, height: 0)
            }
        }
        // The search field's filter suggestions, drawn here rather than off the field itself: a
        // view is not hit-tested outside its parent's bounds, and hung off the field the list took
        // no clicks at all. `SuggestionAnchor` is the only thing that watches `PanelSuggestions`,
        // so a query changing under the cursor never rebuilds the panel.
        .overlay(alignment: .top) { SuggestionAnchor() }
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
                    collapseSelection()
                }
            }
        })
        // SwiftUI gives `.popover` no handle on the NSPopover it creates, so both of the panel's
        // are caught as they open — `PanelPreview` and `PanelFilters` each need theirs to take the
        // popover off the screen directly rather than wait for SwiftUI to agree it is gone.
        //
        // The filter sheet used to have its `animates` turned off here, for a fade measured at
        // "~500ms in, ~550ms out" — but that was measured through `didShow` / `didClose`, and
        // those notifications arrive long after the animation itself. Sampled off the screen the
        // real one is the ~200ms NSPopover default that Paste uses too, so there was never a slow
        // animation to switch off: it only cost the sheet its close.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { note in
            guard let popover = note.object as? NSPopover else { return }
            if filterSheet.isPresented {
                // The one still on record can be a popover already on its way out — AppKit
                // dismisses it as the click that reopens the sheet lands, and its `didClose`
                // arrives after the replacement is up. Take the new one either way, and make
                // sure the old one really goes, or it is left on screen with nothing holding it.
                if let stale = filterSheet.popover, stale !== popover { stale.performClose(nil) }
                filterSheet.popover = popover
                return
            }
            guard preview.itemID != nil, popover !== preview.popover else { return }
            // At most one preview on screen, ever.
            //
            // Measured with two editors open at once: a click landed on the older one while the
            // newer one was what the user could see, so a colour chosen for the visible selection
            // was applied to the hidden document — and appeared only when the top one was closed.
            // The older popover had leaked between two openings of the editor, with the panel
            // never hiding in between, so closing on `.panelWillHide` alone never reached it.
            if let stale = preview.popover { stale.performClose(nil) }
            preview.popover = popover
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { note in
            guard let popover = note.object as? NSPopover else { return }
            if popover === preview.popover { preview.popover = nil }
            guard popover === filterSheet.popover else { return }
            filterSheet.popover = nil
            if filterSheet.isPresented { filterSheet.close() }
        }
        .onChange(of: showSearch) { open in
            // When the search box closes by any path, force the TextField to resign — otherwise it
            // stays first responder while hidden, so the caret keeps blinking there and keystrokes
            // still land in an invisible field. Then restore a live selection (first item if none),
            // but never while the panel is hiding: that path intentionally clears the selection.
            guard !open else { return }
            searchFocused = false
            // The filter button lives in the search field, so its popover has nothing left to
            // hang off once the field folds away.
            filterSheet.close()
            rebaseSelection()
        }
        // Each of these swaps the visible row out from under the selection. Handled here rather
        // than by watching `displayedItems` itself: that would mean filtering the whole history on
        // every body pass just to compare, and ContentView deliberately does not re-render on
        // selection changes.
        .onChange(of: activeTab) { _ in rebaseSelection() }
        .onChange(of: store.searchQuery) { _ in rebaseSelection() }
        .onChange(of: store.filters) { _ in rebaseSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .panelWillHide)) { _ in
            // Only mutate when there is actually something to reset. `store.searchQuery` is
            // @Published and emits even when set to the same value, which would invalidate the
            // whole ContentView and force a ~110ms synchronous re-layout right as the close
            // animation starts — freezing the slide. Guarding keeps the close smooth.
            selection.isHidingPanel = true
            stopPermissionPoll()
            if showSearch { showSearch = false }
            if !store.searchQuery.isEmpty { store.searchQuery = "" }
            // Filters go with the search box: reopening to a silently narrowed history reads
            // as "my clipboard lost everything".
            filterSheet.close()
            if !store.filters.isEmpty { store.filters.clear() }
            selection.clear()
            // The next open starts from a clean row — the list is rewound on `.panelDidHide` —
            // so a request left pointing at the card the user walked to would be answered
            // against a list that has already scrolled back to the front.
            scrollRequest = nil
            preview.close()
            // Drop a half-finished rename rather than reopening the panel into edit mode.
            if renameItemID != nil { renameItemID = nil }
        }
        // Test hook, inert unless the perf harness is running: see `.simulateDragEnd`.
        .onReceive(NotificationCenter.default.publisher(for: .simulateDragEnd)) { note in
            guard PerfLog.enabled,
                  let point = note.userInfo?["screenPoint"] as? NSPoint,
                  let item = displayedItems.first else { return }
            finishDrag(dragPlan(for: item), at: point, operation: [],
                       shiftHeld: note.userInfo?["shift"] as? Bool ?? false, cancelled: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveSelectionBy)) { note in
            guard let delta = note.userInfo?["delta"] as? Int else { return }
            moveSelection(by: delta)
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePreviewSelected)) { _ in
            // Space arrives from AppDelegate's key monitor, which cannot know what is selected.
            guard let item = primarySelectedItem else { return }
            preview.toggle(item.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: .renameSelectedItem)) { _ in
            guard let item = primarySelectedItem else { return }
            beginRename(item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .editSelectedItem)) { _ in
            guard let item = primarySelectedItem, ItemEdit.canEdit(item.type) else { return }
            beginEdit(item)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedItem)) { _ in
            guard let item = primarySelectedItem, let url = linkURL(of: item) else { return }
            NSWorkspace.shared.open(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveSelectedItem)) { _ in
            // ⌘S arrives from AppDelegate's key monitor, which cannot know what is selected.
            guard let item = primarySelectedItem, SaveFormat.canSave(item.type) else { return }
            saveToFile(item)
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
            selection.isHidingPanel = false
            // `AXIsProcessTrusted()` is a synchronous IPC round-trip; running it here put it in
            // the window between the hotkey and the panel starting to slide. The 2s timer below
            // polls the same value, so the banner still appears within a blink of being granted.
            DispatchQueue.main.async {
                let trusted = AccessibilityPermission.isTrusted
                if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
                // Same reasoning as the Accessibility check above: `SMAppService.status` is a
                // round-trip to launchservicesd, so it stays off the hotkey-to-panel path.
                let registered = LoginItem.isEnabled
                if registered != launchesAtLogin { launchesAtLogin = registered }
            }
            // Focus cannot be on a search box that is not on screen. Guarded so the common open
            // costs nothing: writing to a `@FocusState` moves first responder, and the open path
            // has already put it where it wants it.
            if !showSearch, searchFocused { searchFocused = false }
            // Auto-select the first item on open so the keyboard is live immediately:
            // ⌘A selects all, ←/→ move between cards, ⏎ pastes — no click into the list needed.
            if let first = displayedItems.first {
                selection.select(first.id)
            }
            startPermissionPoll()
        }

        // Opening the "…" menu pulls focus off the search field, and the panel's own tap gesture
        // reads that as a click into empty space — collapsing the search and wiping what was typed.
        // The menu is a `Menu`, so there is no action closure to hang the usual flag on; AppKit's
        // own tracking notification is the hook that does not depend on winning a gesture race.
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            searchToggleTapped = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchToggleTapped = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardAlertShown)) { _ in
            alertPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardAlertHidden)) { _ in
            alertPresented = false
        }
        // Borrows the alert handshake so AppDelegate stops swallowing Escape while a name is
        // being typed: Escape must cancel the edit, not close the panel.
        .onChange(of: renameItemID) { id in
            NotificationCenter.default.post(
                name: id != nil ? .clipboardAlertShown : .clipboardAlertHidden,
                object: nil
            )
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

    /// How wide the search row may grow once it opens.
    ///
    /// A measured step up from the 540 it was, not a stretch across the bar: the bar spans nearly
    /// the whole screen, and a field that wide would read as a different piece of furniture. The
    /// row gains 11%, and the text field inside it — which is the row less the two compact tabs —
    /// gains about 14%.
    private let expandedSearchMaxWidth: CGFloat = 600

    /// Trailing space the search row leaves clear for the "…" menu, which now stays put instead of
    /// fading away with the rest of the collapsed layout.
    ///
    /// It matters on a vertical panel, where the bar is only one card wide: there the row fills
    /// what it is given, and without this it would run straight under the button.
    private let moreMenuReserve: CGFloat = 36

    private var toolbar: some View {
        ZStack {
            HStack(spacing: 6) {
                Spacer(minLength: 0)

                SearchIconButton {
                    searchToggleTapped = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchToggleTapped = false }
                    withAnimation(toolbarSpring) { showSearch = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        // The box can have folded away again inside those 50ms: Escape closes the
                        // panel, and `.panelWillHide` closes the search with it. Taking focus then
                        // leaves `searchFocused` true with no search box on screen — an invisible
                        // NSTextField holding the keyboard (both toolbar layouts stay in the
                        // hierarchy, one at opacity 0) and every shortcut guarded by that flag
                        // stood down, for the rest of the panel's life and the next one's.
                        guard showSearch else { return }
                        searchFocused = true
                    }
                }

                tabFull(title: "Clipboard", icon: "clock.arrow.circlepath", tab: .all)
                tabFull(title: "Pinboard", icon: "pin.fill", iconColor: .red, tab: .pinned)

                Spacer(minLength: 0)
            }
            .opacity(showSearch ? 0 : 1)
            .allowsHitTesting(!showSearch)

            HStack(spacing: 8) {
                expandedSearchBar
                tabCompact(icon: "clock.arrow.circlepath", tab: .all)
                tabCompact(icon: "pin.fill", iconColor: .red, tab: .pinned)
            }
            .frame(maxWidth: expandedSearchMaxWidth)
            .padding(.trailing, moreMenuReserve)
            .opacity(showSearch ? 1 : 0)
            .scaleEffect(x: showSearch ? 1 : 0.5, anchor: .center)
            .allowsHitTesting(showSearch)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        // The folded-away search layout still holds a real NSTextField, and AppKit's cursor rects
        // come off the view itself — `.allowsHitTesting(false)` stops its clicks but leaves the
        // I-beam, right under the magnifier and the "Clipboard" tab (which is why those two showed
        // it and "Pin", further right, did not). This lays an arrow cursor rect over the whole
        // toolbar while the field is collapsed. It has to be a cursor rect and not `.disabled`:
        // disabling the row robs the layout underneath of its hover highlight, and disabling the
        // field alone leaves the I-beam behind.
        .overlay { ArrowCursorArea(active: !showSearch).allowsHitTesting(false) }
        .contentShape(Rectangle())
        .onTapGesture {
            guard showSearch else { return }
            // A toolbar control was what got clicked, not the strip behind it — the same 0.3s flag
            // the panel-level gesture honours.
            guard !searchToggleTapped else { return }
            // Closing the search box explicitly drops its filter tokens too — leaving invisible
            // filters applied would look like items had gone missing.
            withAnimation(toolbarSpring) {
                showSearch = false
                store.searchQuery = ""
                if !store.filters.isEmpty { store.filters.clear() }
            }
        }
        // Outside both layers, so it survives the crossfade — the search box opening is not a
        // reason to take the menu away. And added *after* the tap gesture above, so a click on it
        // is hit-tested here first rather than reaching the gesture that would close the search.
        .overlay(alignment: .trailing) {
            MoreMenu { confirmClearHistory() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Lives inside the search field, at its trailing edge.
    private var filterButton: some View {
        FilterIconButton(isActive: !store.filters.isEmpty) {
            // Clicking the button pulls focus out of the text field, and an empty field that
            // loses focus collapses the search — taking this button's popover anchor with it.
            // The same flag the tab buttons use suppresses that for the length of the click.
            searchToggleTapped = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchToggleTapped = false }
            filterSheet.toggle()
        }
        .modifier(FilterAnchor(arrowEdge: previewArrowEdge, filters: $store.filters,
                               appsInHistory: { FilterApp.present(in: store.items) }))
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
        // Everything here is on the same scale as the collapsed toolbar: 13pt regular type, 6pt
        // between elements, and a capsule the same height as a tab's pill, so opening the search
        // changes what the row contains and not how big anything in it is.
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                // Secondary, unlike the toolbar's magnifier, and deliberately: that one is a button
                // you press, this one is a label on the box you are typing into.
                .foregroundColor(.secondary)

            // Guarded rather than left to draw nothing: both toolbar layouts stay in the
            // hierarchy (the hidden one at opacity 0), so this is built on every toolbar pass —
            // including the one on the panel's open path, where no filter is ever set yet.
            if !store.filters.isEmpty {
                ActiveFilterTokens(filters: $store.filters)
            }

            DebouncedSearchField(focused: $searchFocused) {
                guard !searchToggleTapped else { return }
                // Filters live as tokens inside this field: folding it away would hide the only
                // sign that the list is being narrowed.
                guard store.filters.isEmpty else { return }
                withAnimation(toolbarSpring) { showSearch = false }
            }

            filterButton
        }
        // 10 leading, so the magnifier sits under the same margin a tab's label does.
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, minHeight: ToolbarMetrics.rowHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            Capsule()
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
                // 1.5, not 2: the ring was drawn for 15pt type and reads as a heavy border around
                // 13pt.
                .overlay(Capsule().stroke(Color.accentColor, lineWidth: 1.5))
        )
    }

    private var horizontalList: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1).id("h-list-start")
                    LazyHStack(spacing: PanelLayout.cardSpacing) {
                        noticeCards
                        ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                            ClipboardItemCard(
                                item: item, index: index + 1,
                                actions: cardActions(for: item),
                                isRenaming: renameItemID == item.id,
                                onRenameEnd: { endRename($0) },
                                highlightTerm: store.highlightTerm
                            )
                            .overlay(PanelClickOverlay(notification: .cmdClickInPanel) { _, _ in toggleSelection(item.id) })
                            .overlay(PanelClickOverlay(notification: .doubleClickInPanel) { point, size in
                                handleDoubleClick(on: item, at: point, in: size)
                            })
                            .onTapGesture(count: 1) { selectItem(item) }
                            .overlay(CardDragSource(
                                plan: { dragPlan(for: item) },
                                onEnded: { plan, point, operation, shift, cancelled in
                                    finishDrag(plan, at: point, operation: operation,
                                               shiftHeld: shift, cancelled: cancelled)
                                }
                            ))
                            .overlay(CardContextMenu { anchor in cardMenu(for: item, anchor: anchor) })
                            .modifier(PreviewAnchor(item: item, arrowEdge: previewArrowEdge))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, PanelLayout.listTopPadding)
                    .padding(.bottom, PanelLayout.listBottomPadding)
                }
            }
            // Rewinding the list belongs off-screen, not on the open path: scrolling a materialised
            // LazyHStack back to its start measured 5ms with the user already waiting. Doing it
            // once the panel is hidden leaves nothing to rewind by the time it reopens.
            .onReceive(NotificationCenter.default.publisher(for: .panelDidHide)) { _ in
                proxy.scrollTo("h-list-start", anchor: .leading)
            }
            .onChange(of: scrollRequest) { request in
                guard let request else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(request.id, anchor: .center) }
            }
        }
    }

    private var verticalList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: PanelLayout.cardSpacing) {
                    noticeCards
                    ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                        ClipboardItemCard(
                            item: item, index: index + 1,
                            actions: cardActions(for: item),
                            isRenaming: renameItemID == item.id,
                            onRenameEnd: { endRename($0) },
                            highlightTerm: store.highlightTerm
                        )
                        // Hugging the card rather than the row: in this layout the row is wider than
                        // the card, and the drag image is cropped to whatever this overlay covers.
                        .overlay(CardDragSource(
                            plan: { dragPlan(for: item) },
                            onEnded: { plan, point, operation, shift, cancelled in
                                finishDrag(plan, at: point, operation: operation,
                                           shiftHeld: shift, cancelled: cancelled)
                            }
                        ))
                        .frame(maxWidth: .infinity)
                        .overlay(PanelClickOverlay(notification: .cmdClickInPanel) { _, _ in toggleSelection(item.id) })
                        .overlay(PanelClickOverlay(notification: .doubleClickInPanel) { point, size in
                                handleDoubleClick(on: item, at: point, in: size)
                            })
                        .onTapGesture(count: 1) { selectItem(item) }
                        .overlay(CardContextMenu { anchor in cardMenu(for: item, anchor: anchor) })
                        .modifier(PreviewAnchor(item: item, arrowEdge: previewArrowEdge))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
            // Rewound off-screen for the same reason as the horizontal list — see there.
            .onReceive(NotificationCenter.default.publisher(for: .panelDidHide)) { _ in
                if let first = displayedItems.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .onChange(of: scrollRequest) { request in
                guard let request else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(request.id, anchor: .center) }
            }
        }
    }

    /// What an empty row says, in Paste's own words and Paste's own type: one line of 26pt
    /// regular system text in the tertiary label colour, centred in the panel, with no icon
    /// above it. Measured off Paste's panel on a 2x display — "History is empty" inks 356x46
    /// device pixels, i.e. 178x23pt, and its darkest pixel is 185/255 against a 248 background,
    /// which is `tertiaryLabelColor` (black at 0.26) to the byte.
    private var emptyState: some View {
        Text(emptyStateTitle)
            .font(.system(size: 26))
            .foregroundColor(Color(NSColor.tertiaryLabelColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if !store.searchQuery.isEmpty || !store.filters.isEmpty { return "No results" }
        return activeTab == .pinned ? "Pinboard is empty" : "History is empty"
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
    private func cardMenu(for item: ClipboardItem, anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Paste\(targetSuffix)", symbol: "arrow.right.doc.on.clipboard",
                                     key: "\r") { pasteItem(item) })
        if item.text != nil {
            menu.addItem(ClosureMenuItem(title: "Paste as Plain Text", symbol: "text.alignleft",
                                         key: "\r", modifiers: .shift) { pastePlainText(item) })
        }
        if let transformMenu = transformMenu(for: item) {
            let host = NSMenuItem(title: "Paste as", action: nil, keyEquivalent: "")
            host.image = NSImage(systemSymbolName: "textformat.alt", accessibilityDescription: nil)
            host.submenu = transformMenu
            menu.addItem(host)
        }
        // Only meaningful with a multi-item selection, which is exactly when people reach for it.
        if selection.count > 1 {
            menu.addItem(ClosureMenuItem(title: "Paste \(selection.count) Selected Items",
                                         symbol: "list.bullet.rectangle",
                                         key: "\r") { pasteSelected() })
        }
        menu.addItem(ClosureMenuItem(title: "Copy", symbol: "doc.on.doc",
                                     key: "c", modifiers: .command) { copyItem(item) })
        if SaveFormat.canSave(item.type) {
            menu.addItem(ClosureMenuItem(title: "Save as File…", symbol: "square.and.arrow.down",
                                         key: "s", modifiers: .command) { saveToFile(item) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Rename…", symbol: "character.cursor.ibeam",
                                     key: "r", modifiers: .command) { beginRename(item) })
        if ItemEdit.canEdit(item.type) {
            menu.addItem(ClosureMenuItem(title: "Edit…", symbol: "pencil",
                                         key: "e", modifiers: .command) { beginEdit(item) })
        }
        if let url = linkURL(of: item) {
            menu.addItem(ClosureMenuItem(title: "Open URL", symbol: "safari",
                                         key: "o", modifiers: .command) {
                NSWorkspace.shared.open(url)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Delete", symbol: "trash",
                                     key: "\u{8}") { deleteOne(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: item.isPinned ? "Unpin" : "Pin",
                                     symbol: item.isPinned ? "pin.slash" : "pin") { store.togglePin(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Preview", symbol: "eye", key: " ") { preview.present(item.id) })
        menu.addItem(ClosureMenuItem(title: "Share", symbol: "square.and.arrow.up") { [weak anchor] in
            presentShareMenu(for: item, anchor: anchor)
        })
        return menu
    }

    /// Presents the system share picker on demand. Previously the share services were built as a
    /// SwiftUI submenu, which made `.contextMenu` eagerly call `NSSharingService.sharingServices`
    /// for every visible card on every re-layout (~110ms) — freezing selection/paste. Computing
    /// them only when Share is chosen keeps the context menu (and thus every click) cheap.
    ///
    /// `anchor` is the card's own overlay view, so the picker pops up hugging that card. The old
    /// code anchored to `NSApp.keyWindow`'s mouse location, but the panel is non-activating and
    /// never becomes key, so the fallback window it picked put the picker adrift on screen.
    private func presentShareMenu(for item: ClipboardItem, anchor: NSView?) {
        let items = shareItems(for: item)
        guard !items.isEmpty else { return }
        let edge = shareArrowEdge
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: items)
            if let anchor, anchor.window != nil, !anchor.bounds.isEmpty {
                picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
                return
            }
            // The card went away (scrolled out, deleted) between the click and here.
            guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView else { return }
            let loc = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            picker.show(relativeTo: NSRect(origin: loc, size: .zero), of: view, preferredEdge: .minY)
        }
    }

    /// Which side of the card the share picker should sit on — away from the screen edge the
    /// panel is docked to, mirroring `previewArrowEdge`. Card anchor views are unflipped, so
    /// `.maxY` is their top.
    private var shareArrowEdge: NSRectEdge {
        switch panelPosition {
        case "top":   return .minY
        case "left":  return .maxX
        case "right": return .minX
        default:      return .maxY
        }
    }

    private func shareItems(for item: ClipboardItem) -> [Any] {
        let item = ClipboardStore.shared.hydrated(item)
        switch item.type {
        case .url:
            if let text = item.text, let url = URL(string: text) { return [url] }
            return [item.displayText]
        case .text, .color:
            return [item.text ?? item.displayText]
        case .image:
            // Shared out of the app, so the original — same reason as Save as File.
            let data = ClipboardStore.shared.originalImageBytes(for: item)
            if let data, let img = NSImage(data: data) { return [img] }
            return [item.displayText]
        case .file, .folder:
            return item.fileURLs ?? []
        }
    }

    /// "Paste as ▸ Trimmed / Single Line / Pretty JSON / …", or nil when nothing applies.
    ///
    /// Built only while the context menu is being assembled — i.e. once, on an explicit
    /// right-click — because deciding applicability means actually running each transform.
    private func transformMenu(for item: ClipboardItem) -> NSMenu? {
        guard let text = ClipboardStore.shared.fullText(for: item) else { return nil }
        let transforms = TextTransform.applicable(to: text, type: item.type)
        guard !transforms.isEmpty else { return nil }
        let submenu = NSMenu()
        for transform in transforms {
            submenu.addItem(ClosureMenuItem(title: transform.title, symbol: transform.symbol) {
                pasteTransformed(item, using: transform)
            })
        }
        return submenu
    }

    /// Hands the item over to `AppDelegate`, which owns the window work a Save dialog needs — the
    /// panel has to be hidden and the app activated before a modal can be usable. Same shape as
    /// `.pasteClipboardItem`.
    private func saveToFile(_ item: ClipboardItem) {
        NotificationCenter.default.post(name: .saveItemToFile, object: nil,
                                        userInfo: ["itemID": item.id])
    }

    private func pasteTransformed(_ item: ClipboardItem, using transform: TextTransform) {
        // The whole text, not the prefix the card shows: a transform rewrites what gets pasted, and
        // one applied to a truncated copy would paste a truncated result.
        guard let text = ClipboardStore.shared.fullText(for: item),
              let transformed = transform.apply(to: text) else { return }
        writePlainTextAndPaste(transformed, reorder: item.id)
    }

    /// Pastes every selected card at once, in the order they appear in the panel. With one card
    /// selected — or nothing left to join — it falls back to a normal single paste, which can
    /// still carry an image or a real file instead of text.
    private func pasteSelected() {
        let chosen = displayedItems.filter { selection.contains($0.id) }
        guard let joined = MultiPaste.joinedText(for: chosen.map(ClipboardStore.shared.hydrated),
                                                 separator: .stored()) else {
            if let single = chosen.first { pasteItem(single) }
            return
        }
        writePlainTextAndPaste(joined, reorder: chosen.first?.id)
    }

    /// Shared tail of every "paste something other than the item itself" path: put plain text on
    /// the pasteboard, claim the change so the monitor doesn't re-capture it as a new item, and
    /// let AppDelegate press ⌘V.
    private func writePlainTextAndPaste(_ text: String, reorder id: UUID?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardMonitor.shared.markNextChangeAsOwn()
        pendingReorderID = id
        NotificationCenter.default.post(name: .pasteClipboardItem, object: nil)
    }

    /// Double-clicking a card pastes it — except on its title, where it starts a rename, the way
    /// a filename behaves in Finder.
    private func handleDoubleClick(on item: ClipboardItem, at point: CGPoint, in size: CGSize) {
        guard renameItemID == nil else { return }
        if isInTitleZone(point, in: size) {
            beginRename(item)
        } else {
            pasteItem(item)
        }
    }

    /// The card's header strip, minus the source-app icon bleeding in from its right edge. In the
    /// vertical panel the row is wider than the card, so the card's own box is derived first.
    private func isInTitleZone(_ point: CGPoint, in size: CGSize) -> Bool {
        let scale = store.panelScale
        let cardWidth = min(size.width, PanelLayout.cardBaseWidth * scale)
        let left = (size.width - cardWidth) / 2
        let appIconZone = 70 * scale
        return point.y <= PanelLayout.cardHeaderHeight * scale
            && point.x >= left
            && point.x <= left + cardWidth - appIconZone
    }

    /// Opens the preview popover already in edit mode. The popover is where editing lives — it is
    /// the only surface with room to type in and a footer to put Save and Cancel on.
    /// Opens the editor. A window of its own since the popover proved unable to hold one — see
    /// `EditWindowPresenter`.
    private func beginEdit(_ item: ClipboardItem) {
        selection.select(item.id)
        preview.close()
        EditWindowPresenter.shared.present(item)
    }

    /// The link a card opens, if it is a link card at all — what both ⌘O and the menu entry ask.
    private func linkURL(of item: ClipboardItem) -> URL? {
        guard item.type == .url, let text = item.text else { return nil }
        return URL(string: text)
    }

    private func beginRename(_ item: ClipboardItem) {
        // Deselect first: the hidden ⏎/Space/Delete shortcuts act on the selection, and they are
        // disabled while renaming anyway — but a stray selection ring under an edit field reads
        // as if both were live.
        selection.select(item.id)
        renameItemID = item.id
    }

    /// `newName` is nil when the edit was cancelled.
    private func endRename(_ newName: String?) {
        guard let id = renameItemID else { return }
        renameItemID = nil
        guard let newName else { return }
        store.setLabel(newName, for: id)
    }

    private var isRenaming: Bool { renameItemID != nil }

    /// Pin / delete for the buttons a card shows while hovered. Sharing stays in the right-click
    /// menu, where the picker can anchor to the card's own AppKit view.
    private func cardActions(for item: ClipboardItem) -> CardActions {
        CardActions(
            isPinned: item.isPinned,
            togglePin: { store.togglePin(item) },
            delete: { deleteOne(item) }
        )
    }

    /// ⌫ / ⌘⌫: delete what is selected, asking first when that is more than one card.
    ///
    /// Gated inside the action rather than with `.disabled(selection.isEmpty)`: ContentView no
    /// longer re-renders on selection changes, so a disabled-state read in `body` would go stale
    /// the moment the selection moved.
    ///
    /// The ids are captured here, not read again when the dialog answers — the dialog does not
    /// hold the panel still, and deleting whatever happened to be selected a second later is not
    /// what the question asked about.
    private func deleteSelection() {
        let ids = selection.ids
        guard !ids.isEmpty else { return }
        guard ids.count > 1 else {
            deleteKeepingSelection(ids)
            return
        }
        DeleteConfirmPresenter.shared.confirm(
            message: "Delete \(ids.count) selected items?",
            confirmTitle: "Delete"
        ) {
            deleteKeepingSelection(ids)
        }
    }

    private func confirmClearHistory() {
        DeleteConfirmPresenter.shared.confirm(
            message: "Delete all unpinned clipboard history?",
            confirmTitle: "Clear History"
        ) {
            store.clearUnpinned()
        }
    }

    /// Deletes one card from the hover button or the right-click menu.
    ///
    /// Only a card that held the selection hands it on — deleting some other card must not move
    /// the highlight out from under whatever the user had chosen.
    private func deleteOne(_ item: ClipboardItem) {
        if selection.contains(item.id) {
            deleteKeepingSelection([item.id])
        } else {
            store.delete(item)
        }
    }

    /// Puts the highlight back on something real after the visible row changed underneath it.
    ///
    /// Never while the panel is hiding: that path clears the selection on purpose.
    private func rebaseSelection() {
        guard !selection.isHidingPanel else { return }
        let items = displayedItems
        guard let rebased = PanelSelection.rebased(in: items.map(\.id),
                                                   selected: selection.ids) else { return }
        selection.set(rebased)
    }

    /// A click into the panel's empty space: drop a multi-selection back to one card.
    ///
    /// This runs a runloop tick late, by design — it has to wait to learn whether the click landed
    /// on a card. So it is also the last word on the selection after a tab switch or a closing
    /// search box, and clearing here used to wipe what `rebaseSelection` had just put back.
    private func collapseSelection() {
        guard !selection.isHidingPanel else { return }
        selection.set(PanelSelection.collapsed(in: displayedItems.map(\.id),
                                               selected: selection.ids))
    }

    /// Deletes, then leaves the selection on whatever survives.
    ///
    /// Backspace used to clear the selection outright, so deleting a run of cards meant reaching
    /// for the mouse between every one: the second press had nothing left to act on.
    ///
    /// The survivor is worked out before the delete, on the row as it stands — afterwards the gap
    /// the deleted cards left is gone and there is nothing to reason from.
    private func deleteKeepingSelection(_ ids: Set<UUID>) {
        let heir = PanelSelection.survivor(in: displayedItems.map(\.id), deleting: ids)
        store.deleteItems(ids: ids)
        if let heir {
            selection.set([heir])
        } else {
            selection.clear()
        }
    }

    /// What a drag out of the panel carries. Read at the moment the drag starts, so a selection
    /// changed since the card was built is the one that travels.
    private func dragPlan(for item: ClipboardItem) -> DragPaste.Plan {
        DragPaste.plan(dragging: item,
                       selection: selection.ids,
                       displayed: displayedItems,
                       accessibilityTrusted: accessibilityTrusted)
    }

    /// A drag has ended.
    ///
    /// Nothing has touched the pasteboard until this point, which is what lets a cancelled drag leave
    /// the user's clipboard exactly as it was.
    private func finishDrag(_ plan: DragPaste.Plan, at point: NSPoint,
                            operation: NSDragOperation, shiftHeld: Bool, cancelled: Bool) {
        guard !cancelled else {
            NotificationCenter.default.post(name: .panelDragCancelled, object: nil)
            return
        }
        // The target took the drop and has already done the work — a file copied into Finder, a
        // picture dropped into an upload zone. Pasting on top of that would deliver it twice.
        if plan.kind == .native, !operation.isEmpty {
            reorderAfterDrag(plan)
            return
        }
        guard let content = DragPaste.content(
            for: plan,
            shiftHeld: shiftHeld,
            alwaysPlainText: UserDefaults.standard.bool(forKey: "alwaysPastePlainText"),
            separator: .stored()
        ) else { return }

        DragPaste.deliver(content)

        var info: [String: Any] = [:]
        // The release point names the application; failing that, the app the panel was opened in
        // front of, which is almost always the one meant anyway.
        if let pid = DropTargetResolver.pid(under: point) { info["targetPID"] = pid }
        if let length = DragPaste.selectableLength(of: content) { info["selectLength"] = length }
        NotificationCenter.default.post(name: .pasteClipboardItem, object: nil, userInfo: info)
        reorderAfterDrag(plan)
    }

    /// Brings the dragged item back to the front of the history, which is what ⏎ and a double-click
    /// already do and dragging did not. The panel is hidden by now, so the store is not publishing
    /// and this costs no layout.
    private func reorderAfterDrag(_ plan: DragPaste.Plan) {
        guard let first = plan.items.first,
              let live = store.items.first(where: { $0.id == first.id }) else { return }
        store.moveToTop(live)
    }

    private func copyItem(_ item: ClipboardItem) {
        item.copyToPasteboard()
        withAnimation(.spring(response: 0.3)) { store.moveToTop(item) }
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
        // `writePlainTextAndPaste` also tells the monitor the change is ours; otherwise it
        // re-captures the pasted text with the target app as the source and overwrites the
        // item's real source app.
        writePlainTextAndPaste(ClipboardStore.shared.fullText(for: item) ?? item.displayText,
                               reorder: item.id)
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

    private func selectItem(_ item: ClipboardItem) {
        selection.suppressCardDeselect = true
        selection.select(item.id)
    }

    /// See `permissionPoll`. Never started once the answer is settled.
    private func startPermissionPoll() {
        guard permissionPoll == nil, !accessibilityTrusted else { return }
        permissionPoll = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                let trusted = AccessibilityPermission.isTrusted
                guard trusted != accessibilityTrusted else { return }
                accessibilityTrusted = trusted
                if trusted { stopPermissionPoll() }
            }
    }

    private func stopPermissionPoll() {
        permissionPoll?.cancel()
        permissionPoll = nil
    }

    /// Moves the selection one card along in display order and asks the list to scroll it into
    /// view. The press itself is read in `AppDelegate`'s key monitor — see `PanelArrowKey`.
    private func moveSelection(by delta: Int) {
        guard let target = PanelSelection.moved(in: displayedItems.map(\.id),
                                                selected: selection.ids, by: delta)
        else { return }
        // No `suppressCardDeselect` here: that flag only exists to stop the ancestor tap
        // handler from clearing a selection made by a card *click*. Arrow-key navigation
        // produces no tap, so leaving it set would swallow the user's next empty-space click.
        selection.select(target)
        // A fresh request every press, even onto the card the list was last asked about: the
        // selection can have reached it by a click or a rebase in between, leaving the row
        // scrolled somewhere else entirely.
        scrollRequest = PanelScrollRequest(id: target, after: scrollRequest)
    }
}

/// An arrow cursor laid over whatever is beneath it.
///
/// Cursor rects are AppKit's, not SwiftUI's: a view registers one and the window hands out that
/// cursor for the area, with the frontmost registration winning — independently of hit-testing, so
/// this takes no clicks and no hover away from the buttons underneath. Used by the toolbar to keep
/// the collapsed search field's I-beam off the magnifier and the tabs.
private struct ArrowCursorArea: NSViewRepresentable {
    /// Off while the search field is open, so the field keeps its own I-beam.
    let active: Bool

    final class CursorView: NSView {
        var active = true

        override func resetCursorRects() {
            guard active else { return }
            addCursorRect(bounds, cursor: .arrow)
        }

        /// Never in the way of the SwiftUI views below — only the cursor rect matters.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> CursorView { CursorView() }

    func updateNSView(_ view: CursorView, context: Context) {
        view.active = active
        // Frames move as the toolbar animates; the window caches cursor rects until told otherwise.
        view.window?.invalidateCursorRects(for: view)
    }
}

/// The search bar's filter button. Carries a dot while any filter is on, so a narrowed list is
/// never mistaken for an empty history.
private struct FilterIconButton: View {
    let isActive: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(isActive ? Color.accentColor : .secondary)
            .padding(5)
            .background(Circle().fill(hovered ? ToolbarTint.hovered : .clear))
            .overlay(alignment: .topTrailing) {
                if isActive {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .offset(x: -1, y: 1)
                }
            }
            .onHover { hovered = $0 }
            .onTapGesture { onTap() }
            .help("Filter by type, app, or date")
    }
}

private struct SearchIconButton: View {
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: "magnifyingglass")
            // 17 regular. Measured against Paste's side by side: 16.0 x 16.5pt with a 2-3px stroke,
            // against this one's 15.5 x 15.5pt with a flat 3px — a shade small and a shade heavy.
            .font(.system(size: 17, weight: .regular))
            .foregroundColor(Color(NSColor.labelColor))
            .padding(7)
            .background(Capsule().fill(ToolbarTint.fill(selected: false, hovered: hovered)))
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
            Button {
                NotificationCenter.default.post(name: .openUpdateWindow, object: nil)
            } label: {
                Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
            }
            Button { NSApplication.shared.terminate(nil) } label: {
                Label("Quit xPaste", systemImage: "power")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Outside the `Menu`, not inside its label, and that is the whole fix. This style hands the
        // label to its own AppKit control, which re-renders it: a `.background` written in there is
        // simply dropped, which is why the hover has never appeared. Measured alongside, the font
        // is ignored the same way — the glyph came out 12.0 x 2.5pt whether it was told 15 semibold
        // or 18 regular.
        //
        // The tint was `controlColor` besides, which lightens, in a bar where every other hover and
        // every selected pill now darkens. Shape and height come from the tabs, so this is the same
        // highlight they get.
        .padding(.horizontal, 10)
        .frame(height: ToolbarMetrics.rowHeight)
        .background(Capsule().fill(ToolbarTint.fill(selected: false, hovered: hovered)))
        .onHover { hovered = $0 }
    }
}

/// The toolbar's selection tint.
///
/// Every number here was measured off a screenshot of Paste's toolbar rather than guessed. Its
/// selected pill reads `#B9BCC1` against a `#C9CCD2` bar — a *darkening* of about 8%, where this
/// toolbar used to lay `controlColor` over the glass and so lightened instead. `Color.primary`
/// rather than black keeps that relationship the right way round in dark mode.
/// The height every control in the toolbar shares.
///
/// 29.5pt, which is what Paste's selected pill measures and what this bar's full tab arrives at on
/// its own. The search capsule and the compact tabs are given it explicitly rather than left to
/// reach it through padding: they hold different things — a text field, a lone glyph — and each was
/// landing somewhere slightly different, which is visible the moment they sit in a row together.
///
/// The search capsule takes it as a *minimum*, not a fixed height: filter tokens live inside that
/// field and have to be able to make it taller.
enum ToolbarMetrics {
    static let rowHeight: CGFloat = 29.5
}

enum ToolbarTint {
    // Tuned by measuring, not by arithmetic. `Color.primary` is `labelColor` — black at 85% alpha
    // rather than black — and composited through the panel's material it lands at roughly 0.64 of
    // what is asked for, which no amount of reasoning about alpha was going to predict exactly.
    //
    // The target is the ratio, which is what survives the glass: Paste's pill measures 8.42% darker
    // than the bar it sits on (#B9BCC1 on #CACCD2). 0.08 gave 5.6% and 0.10 gave 6.4%; 0.13 lands
    // on it. The ratio is the right thing to match because a multiplicative darkening is the same
    // proportion whatever the wallpaper behind the panel happens to be.
    static let selected = Color.primary.opacity(0.13)
    static let hovered = Color.primary.opacity(0.065)

    static func fill(selected: Bool, hovered: Bool) -> Color {
        selected ? Self.selected : (hovered ? Self.hovered : .clear)
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
            // 6, not 5: the gap between Paste's clock and its label measures 8pt against the 7pt
            // this was leaving.
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(iconColor ?? Color(NSColor.labelColor))
                Text(title)
                    // One weight, whichever tab is selected. A measurement said otherwise — Paste's
                    // selected label came out at 3px stems against its unselected 2px — but that
                    // was the measurement lying: it thresholded on absolute luminance, and the
                    // selected label sits on a pill that is darker than the bar, so more of its
                    // antialiased edge fell below the line. The pill is the whole of the selection.
                    //
                    // 13, not 14. The same word in both bars: "Clipboard" sets 56.5pt wide in
                    // Paste and was setting 60.5pt here, and the clock beside it was out by the
                    // same 7%. The stems that measured a pixel heavier were that size difference,
                    // not a heavier weight.
                    .font(.system(size: 13, weight: .regular))
                    // Full label colour whether or not this tab is the selected one. Measured: the
                    // unselected label is `#262629` against the selected one's `#222325`, so the
                    // pill is the only thing marking the selection. Dimming the text as well, which
                    // is what this did, made an unselected tab read as disabled.
                    .foregroundColor(Color(NSColor.labelColor))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: ToolbarMetrics.rowHeight)
            .background(Capsule().fill(ToolbarTint.fill(selected: isSelected, hovered: hovered)))
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
                // Bigger than the full tab's 13, and on purpose: with no label beside it this glyph
                // is the whole button. Regular weight, like everything else in the bar.
                .font(.system(size: 15, weight: .regular))
                // Undimmed, like the full tab: the pill carries the selection on its own.
                .foregroundColor(iconColor ?? Color(NSColor.labelColor))
                .padding(.horizontal, 10)
                .frame(height: ToolbarMetrics.rowHeight)
                .background(Capsule().fill(ToolbarTint.fill(selected: isSelected, hovered: hovered)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// Reports panel-wide clicks that landed on this view, with the click point in the view's own
/// (top-left origin) coordinates and the view's size — so a caller can tell *where* on a card
/// the click landed: the title bar means "rename", the rest means "paste".
private struct PanelClickOverlay: NSViewRepresentable {
    let notification: Notification.Name
    let action: (CGPoint, CGSize) -> Void

    func makeNSView(context: Context) -> PanelClickView {
        PanelClickView(notification: notification, action: action)
    }

    func updateNSView(_ nsView: PanelClickView, context: Context) {
        nsView.action = action
    }
}

private final class PanelClickView: NSView {
    let notification: Notification.Name
    var action: (CGPoint, CGSize) -> Void
    private var observer: NSObjectProtocol?

    init(notification: Notification.Name, action: @escaping (CGPoint, CGSize) -> Void) {
        self.notification = notification
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let obs = observer { NotificationCenter.default.removeObserver(obs) }
    }

    /// Flipped so the reported point is measured from the top of the card, which is how the card
    /// is laid out (header first) and how callers reason about it.
    override var isFlipped: Bool { true }

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
                self.action(pt, self.bounds.size)
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
    @State private var backspaceMonitor: Any?
    private static let debounceNanos: UInt64 = 80_000_000
    /// Backspace/Delete.
    private static let deleteKeyCode: UInt16 = 51
    private static let returnKeyCode: UInt16 = 36
    private static let enterKeyCode: UInt16 = 76
    private static let tabKeyCode: UInt16 = 48
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125

    /// Hands `PanelSuggestions` the filters this query could become.
    ///
    /// Computed here rather than in `ContentView`: this view already rebuilds on every keystroke
    /// and the panel deliberately does not — binding the query straight to the store cost a
    /// full-panel re-layout per character, which is the whole reason this field exists. Only the
    /// rows travel up, and only the one small view that draws them reacts.
    private func publishSuggestions() {
        guard !text.isEmpty else {
            PanelSuggestions.shared.clear()
            return
        }
        let resolver = AppNameResolver.shared
        PanelSuggestions.shared.show(FilterSuggestion.matching(
            query: text,
            apps: FilterSuggestion.apps(in: store.items, name: { resolver.name(for: $0) }),
            active: store.filters
        ))
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    // Shown whenever the field is empty, focused or not: the search box opens
                    // already focused, so gating on !focused hid it exactly when it was
                    // the only thing telling you what the empty box was for.
                    if text.isEmpty {
                        Text("Search...")
                            .font(.system(size: 13))
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
        .onAppear { PanelSuggestions.shared.take = pick }
        .onChange(of: text) { _ in publishSuggestions() }
        .onChange(of: store.filters) { _ in publishSuggestions() }
        .onChange(of: text) { new in
            debounce?.cancel()
            debounce = Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.debounceNanos)
                guard !Task.isCancelled else { return }
                push(new)
            }
        }
        .onChange(of: focused) { isFocused in
            // The key monitor only exists while this field has the keyboard, so it can never
            // swallow a Delete meant for a selected card or a Return meant for a paste.
            if isFocused { installKeyMonitor() } else { removeKeyMonitor() }

            // Losing focus with a live query means the user clicked into the results (e.g. to
            // double-click-paste). Keep the search open so the filtered list stays put and the
            // paste hits the right item. Only auto-close when nothing was typed.
            guard !isFocused, text.isEmpty else { return }
            onEmptyBlur()
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelWillHide)) { _ in
            debounce?.cancel()
            if !text.isEmpty { text = "" }
            PanelSuggestions.shared.clear()
        }
        .onDisappear {
            debounce?.cancel()
            removeKeyMonitor()
            PanelSuggestions.shared.clear()
        }
    }

    /// The keys the field has to take before anything else does, while it holds the keyboard.
    ///
    /// A local monitor rather than a custom `NSTextField`: the field itself is a plain SwiftUI
    /// `TextField`, and these are the only keys it needs to intercept. Backspace on an empty field
    /// deletes the last filter token, the way any token field behaves; ↑ / ↓ / Return / Tab drive
    /// the suggestion list, and only while there is one — with no suggestions up, Return still
    /// belongs to whatever the panel does with it.
    private func installKeyMonitor() {
        guard backspaceMonitor == nil else { return }
        backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard focused else { return event }
            // The arrow keys arrive carrying `.numericPad` and `.function` — every arrow on a Mac
            // keyboard does — so those cannot count as modifiers here or ↑ / ↓ never reach the
            // list. Caps Lock is not a binding anyone makes either.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            guard mods.isEmpty else { return event }

            if event.keyCode == Self.deleteKeyCode, text.isEmpty, !store.filters.isEmpty {
                let resolver = AppNameResolver.shared
                store.filters.removeLastToken(appName: { resolver.name(for: $0) })
                return nil
            }

            let list = PanelSuggestions.shared
            guard !list.rows.isEmpty else { return event }
            switch event.keyCode {
            case Self.downArrowKeyCode:
                list.move(by: 1)
                return nil
            case Self.upArrowKeyCode:
                list.move(by: -1)
                return nil
            case Self.returnKeyCode, Self.enterKeyCode, Self.tabKeyCode:
                if let row = list.current { pick(row) }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        guard let monitor = backspaceMonitor else { return }
        NSEvent.removeMonitor(monitor)
        backspaceMonitor = nil
    }

    /// Turns the query into the filter it was naming: the token appears in the field, the text it
    /// was typed as goes, and the keyboard stays here so the next filter can be typed straight
    /// after — the field is where filters live, so leaving it after each one would be backwards.
    private func pick(_ suggestion: FilterSuggestion) {
        var next = store.filters
        suggestion.apply(to: &next)
        store.filters = next
        apply("", immediately: true)
        PanelSuggestions.shared.clear()
        focused = true
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
///
/// The builder is handed the overlay view itself: it covers exactly the card's frame, which makes
/// it the anchor for anything the menu pops up next to it (the share picker).
private struct CardContextMenu: NSViewRepresentable {
    let build: (NSView) -> NSMenu

    func makeNSView(context: Context) -> CardContextMenuView { CardContextMenuView(build: build) }
    func updateNSView(_ nsView: CardContextMenuView, context: Context) { nsView.build = build }
}

private final class CardContextMenuView: NSView {
    var build: (NSView) -> NSMenu

    init(build: @escaping (NSView) -> NSMenu) {
        self.build = build
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Kept unflipped so `shareArrowEdge`'s `.maxY` really means "above the card".
    override var isFlipped: Bool { false }

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

    override func menu(for event: NSEvent) -> NSMenu? { build(self) }
}

/// Carries one card's preview popover, and is the only thing in the panel that watches
/// `PanelPreview`.
///
/// The popover used to be attached with a binding built from `ContentView`'s own `@State`, read
/// inside the card loop — so opening a preview rebuilt the whole panel before the popover was
/// created. Anchoring it here keeps that work to one small node per card: the card bodies, the
/// toolbar and the scroll view are all untouched by a preview opening or closing.
struct PreviewAnchor: ViewModifier {
    let item: ClipboardItem
    let arrowEdge: Edge
    @ObservedObject private var preview = PanelPreview.shared

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { preview.itemID == item.id },
                // Dismissals AppKit runs on its own — a click outside, or the popover's own close
                // — arrive here and nowhere else.
                set: { shown in if !shown { preview.close() } }
            ),
            arrowEdge: arrowEdge
        ) {
            PreviewPopoverContent(item: item) { preview.close() }
        }
    }
}

/// Carries the filter sheet, and is the only thing in the panel that watches `PanelFilters`.
///
/// Same shape, and same reason, as `PreviewAnchor`: bound to `ContentView`'s own state the sheet
/// could not open without rebuilding the toolbar, the search field and every card first.
struct FilterAnchor: ViewModifier {
    let arrowEdge: Edge
    @Binding var filters: SearchFilters
    let appsInHistory: () -> [FilterApp]
    @ObservedObject private var sheet = PanelFilters.shared

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { sheet.isPresented },
                // SwiftUI reports a popover's dismissal late — late enough that on a fast
                // double press the report for the popover that just went lands *after* the
                // press has already opened the next one, and this setter then closed the new
                // one on the old one's behalf. That is the flicker-and-vanish people see when
                // they spam the filter button: measured, every second press opened a popover
                // and had it shut ~10ms later. A dismissal only counts when nothing is on
                // screen; when a live popover is up, `didCloseNotification` owns the close.
                set: { shown in
                    guard !shown else { return }
                    if let live = sheet.popover, live.isShown { return }
                    sheet.close()
                }
            ),
            arrowEdge: arrowEdge
        ) {
            // The sheet resolves the app list itself, when it appears. Computing it in the tap
            // handler leaves the App section missing on the panel's first open: SwiftUI builds
            // that first presentation from a copy of the presenting view taken before the tap's
            // state change lands, so it sees an empty list.
            FilterPopover(filters: $filters, appsInHistory: appsInHistory)
        }
    }
}
