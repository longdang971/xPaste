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
    @State private var copiedID: UUID?
    @State private var showSearch = false
    @State private var previewItemID: UUID?
    @State private var scrollTargetID: UUID?
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
    @State private var showFilters = false
    /// The live NSPopover behind the filter sheet while it is open — see the notification
    /// handlers on `body` for why it has to be held onto.
    @State private var filterPopover: NSPopover?
    /// The live NSPopover behind the item preview, held for one reason: closing it directly.
    ///
    /// Clearing `previewItemID` asks SwiftUI to dismiss it, and SwiftUI does that on its next pass
    /// — through a hosting view whose window is in the middle of being ordered out. When that pass
    /// does not land, the popover stays on screen with its parent gone: not key, no first
    /// responder, and its own close button running the same state change that already failed. So
    /// the panel closes it by hand as well.
    @State private var previewPopover: NSPopover?
    @FocusState private var searchFocused: Bool
    @State private var accessibilityTrusted = AccessibilityPermission.isTrusted
    @AppStorage("accessibilityBannerDismissed") private var accessibilityBannerDismissed = false
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
                .disabled(searchFocused || isRenaming)
                .opacity(0)
                .frame(width: 0, height: 0)

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
                    Button("") { if let it = primarySelectedItem { togglePreview(it) } }
                        .keyboardShortcut(.space, modifiers: [])
                }
                .disabled(searchFocused || isRenaming)
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
                    collapseSelection()
                }
            }
        })
        // SwiftUI gives `.popover` no handle on the NSPopover it creates, so the filter sheet's
        // is caught as it opens. Two things measured on the real panel need it:
        //
        //  • Its fade runs ~500ms in and ~550ms out. `animates = false` lands too late to shorten
        //    the opening fade — SwiftUI builds a fresh popover per presentation — but it does make
        //    the close instant (measured 550ms → 5ms), which is most of what "slow" felt like.
        //  • `isPresented` is written back long after the popover has actually gone. Clicking the
        //    button in that gap made `showFilters.toggle()` flip a still-true flag to false, so
        //    the click that should have reopened the sheet did nothing. Clearing the flag the
        //    moment AppKit says the popover closed keeps the two in step.
        //
        // Matched by identity, so the item-preview popover — which wants its animation — is
        // untouched.
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.willShowNotification)) { note in
            guard let popover = note.object as? NSPopover else { return }
            if showFilters, filterPopover == nil {
                popover.animates = false
                filterPopover = popover
                return
            }
            guard previewItemID != nil, popover !== previewPopover else { return }
            // At most one preview on screen, ever.
            //
            // Measured with two editors open at once: a click landed on the older one while the
            // newer one was what the user could see, so a colour chosen for the visible selection
            // was applied to the hidden document — and appeared only when the top one was closed.
            // The older popover had leaked between two openings of the editor, with the panel
            // never hiding in between, so closing on `.panelWillHide` alone never reached it.
            if let stale = previewPopover { stale.performClose(nil) }
            previewPopover = popover
        }
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { note in
            guard let popover = note.object as? NSPopover else { return }
            if popover === previewPopover { previewPopover = nil }
            guard popover === filterPopover else { return }
            filterPopover = nil
            if showFilters { showFilters = false }
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
            if showFilters { showFilters = false }
            rebaseSelection()
        }
        // Each of these swaps the visible row out from under the selection. Handled here rather
        // than by watching `displayedItems` itself: that would mean filtering the whole history on
        // every body pass just to compare, and ContentView deliberately does not re-render on
        // selection changes.
        // Whatever cleared it — Save, Escape, the close button, the item being deleted — the
        // window goes with it. Relying on SwiftUI to notice is what left one on screen.
        .onChange(of: previewItemID) { id in if id == nil { closePreviewPopover() } }
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
            if showFilters { showFilters = false }
            if !store.filters.isEmpty { store.filters.clear() }
            selection.clear()
            // Both, in this order: the state change is what SwiftUI needs to agree the popover is
            // gone, and the direct close is what guarantees it actually goes — see `previewPopover`.
            if previewItemID != nil { previewItemID = nil }
            closePreviewPopover()
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
            }
            // Auto-select the first item on open so the keyboard is live immediately:
            // ⌘A selects all, ←/→ move between cards, ⏎ pastes — no click into the list needed.
            if let first = displayedItems.first {
                selection.select(first.id)
            }
            startPermissionPoll()
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
                MoreMenu { confirmClearHistory() }
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
            // Closing the search box explicitly drops its filter tokens too — leaving invisible
            // filters applied would look like items had gone missing.
            withAnimation(toolbarSpring) {
                showSearch = false
                store.searchQuery = ""
                if !store.filters.isEmpty { store.filters.clear() }
            }
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
            showFilters.toggle()
        }
        .popover(isPresented: $showFilters, arrowEdge: previewArrowEdge) {
            // The sheet resolves the app list itself, when it appears. Computing it here — or in
            // the tap handler above — leaves the App section missing on the panel's first open:
            // SwiftUI builds that first presentation from a copy of this view taken before the
            // tap's state change lands, so it sees an empty list. `store` is a reference, so the
            // closure reads the live history however stale the copy around it is.
            FilterPopover(filters: $store.filters) { FilterApp.present(in: store.items) }
        }
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
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
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
                                item: item, index: index + 1, isCopied: copiedID == item.id,
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
                            .popover(isPresented: previewBinding(for: item), arrowEdge: previewArrowEdge) {
                                PreviewPopoverContent(item: item) {
                                    previewItemID = nil
                                    closePreviewPopover()
                                }
                            }
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
                            item: item, index: index + 1, isCopied: copiedID == item.id,
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
                        .popover(isPresented: previewBinding(for: item), arrowEdge: previewArrowEdge) {
                            PreviewPopoverContent(item: item) {
                                previewItemID = nil
                                closePreviewPopover()
                            }
                        }
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
        menu.addItem(ClosureMenuItem(title: "Rename…",
                                     symbol: "character.cursor.ibeam") { beginRename(item) })
        if ItemEdit.canEdit(item.type) {
            menu.addItem(ClosureMenuItem(title: "Edit…", symbol: "pencil") { beginEdit(item) })
        }
        if item.type == .url, let text = item.text, let url = URL(string: text) {
            menu.addItem(ClosureMenuItem(title: "Open URL", symbol: "safari") {
                NSWorkspace.shared.open(url)
            })
        }
        menu.addItem(ClosureMenuItem(title: "Delete", symbol: "trash",
                                     key: "\u{8}") { deleteOne(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: item.isPinned ? "Unpin" : "Pin",
                                     symbol: item.isPinned ? "pin.slash" : "pin") { store.togglePin(item) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Preview", symbol: "eye", key: " ") { previewItemID = item.id })
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
        if previewItemID != nil { previewItemID = nil }
        closePreviewPopover()
        EditWindowPresenter.shared.present(item)
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

    private func previewBinding(for item: ClipboardItem) -> Binding<Bool> {
        Binding(
            get: { previewItemID == item.id },
            set: { show in if !show { previewItemID = nil } }
        )
    }

    /// Takes the preview popover off the screen itself, whatever SwiftUI does about it.
    private func closePreviewPopover() {
        guard let popover = previewPopover else { return }
        previewPopover = nil
        popover.performClose(nil)
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

/// The search bar's filter button. Carries a dot while any filter is on, so a narrowed list is
/// never mistaken for an empty history.
private struct FilterIconButton: View {
    let isActive: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isActive ? Color.accentColor : .secondary)
            .padding(6)
            .background(Circle().fill(hovered ? Color(NSColor.controlColor) : .clear))
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
            Button {
                NotificationCenter.default.post(name: .openUpdateWindow, object: nil)
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
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
            // The backspace monitor only exists while this field has the keyboard, so it can
            // never swallow a Delete meant for a selected card.
            if isFocused { installBackspaceMonitor() } else { removeBackspaceMonitor() }

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
        .onDisappear {
            debounce?.cancel()
            removeBackspaceMonitor()
        }
    }

    /// Backspace on an empty field deletes the last filter token, the way any token field
    /// behaves. A local monitor rather than a custom `NSTextField`: the field itself is a plain
    /// SwiftUI `TextField`, and this is the one key it needs to intercept.
    private func installBackspaceMonitor() {
        guard backspaceMonitor == nil else { return }
        backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == Self.deleteKeyCode,
                  focused,
                  text.isEmpty,
                  !store.filters.isEmpty
            else { return event }
            let resolver = AppNameResolver.shared
            store.filters.removeLastToken(appName: { resolver.name(for: $0) })
            return nil
        }
    }

    private func removeBackspaceMonitor() {
        guard let monitor = backspaceMonitor else { return }
        NSEvent.removeMonitor(monitor)
        backspaceMonitor = nil
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
