import SwiftUI
import AppKit

/// One app that actually appears in the history, ready to draw as a chip.
struct FilterApp: Identifiable, Equatable {
    let bundleID: String
    var id: String { bundleID }
    let name: String
    let icon: NSImage?

    /// The apps present in `items`, resolved and sorted by name. Built when the popover opens
    /// rather than kept in the store: it touches LaunchServices, and nothing needs it until
    /// someone actually asks to filter.
    static func present(in items: [ClipboardItem]) -> [FilterApp] {
        let resolver = AppNameResolver.shared
        let ids = Set(items.compactMap(\.sourceAppBundleID))
        return ids.map { id in
            FilterApp(bundleID: id, name: resolver.name(for: id) ?? id, icon: resolver.icon(for: id))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The filter sheet behind the search bar's filter button: narrow the history by kind, by the
/// app it came from, and by when it was copied.
struct FilterPopover: View {
    @Binding var filters: SearchFilters
    /// Asked for the app list when the sheet appears, rather than handed one when it is built.
    /// SwiftUI can build the first presentation from a copy of the presenting view made before
    /// the tap that opened it landed, so a snapshot passed in arrives empty on the panel's first
    /// open; resolving here reads the history at a point where it is certainly there. It also
    /// keeps LaunchServices off the toolbar's render path, which was the point of not keeping
    /// this list in the store.
    let appsInHistory: () -> [FilterApp]

    @State private var apps: [FilterApp] = []

    private let columns = [GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("Type") {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(FilterType.allCases) { type in
                            FilterChip(title: type.title,
                                       symbol: type.symbol,
                                       isOn: filters.types.contains(type)) {
                                filters.toggle(type)
                            }
                        }
                    }
                }

                if !apps.isEmpty {
                    section("App") {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(apps) { app in
                                FilterChip(title: app.name,
                                           icon: app.icon,
                                           isOn: filters.apps.contains(app.bundleID)) {
                                    filters.toggle(app: app.bundleID)
                                }
                            }
                        }
                    }
                }

                section("Date") {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(DateFilter.allCases) { date in
                            FilterChip(title: date.title,
                                       symbol: "calendar",
                                       isOn: filters.date == date) {
                                filters.toggle(date: date)
                            }
                        }
                    }
                }

                if !filters.isEmpty {
                    Button {
                        filters.clear()
                    } label: {
                        Label("Clear filters", systemImage: "xmark.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            .padding(16)
        }
        .frame(width: 420, height: 330)
        .onAppear { apps = appsInHistory() }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// The active filters, drawn as tokens inside the search field — so a narrowed list always says
/// on its face *why* it is narrowed. Clicking a token drops that one filter.
/// How wide a row of filter tokens comes out, and how many of them fit.
///
/// Seven active filters filled the search bar edge to edge and left the text field a sliver. The
/// ones past the budget collapse behind a counter chip instead.
///
/// Measured rather than counted: an app filter's token carries the app's real name, so "Transmit"
/// and "Visual Studio Code" are not remotely the same size and a fixed "show the first three"
/// would be wrong in both directions.
enum FilterTokenLayout {
    /// Everything `FilterToken` puts around its label: 4pt leading padding, a 14pt icon, the 4pt
    /// HStack spacing, and 7pt trailing padding.
    static let tokenChrome: CGFloat = 29
    /// The gap between two tokens — `ActiveFilterTokens`' own HStack spacing.
    static let spacing: CGFloat = 5
    /// The "+3" chip: a small plus, the count, and the same padding as a token.
    static let counterWidth: CGFloat = 34

    /// The width the token row may take before the text field starts to suffer.
    ///
    /// The bar is capped at 540pt (`ContentView.toolbar`) and out of that the two compact tabs take
    /// ~88pt, its own padding 18pt, the magnifier ~22pt and the filter button ~28pt. Leaving the
    /// field ~150pt to type in puts the tokens at what is left.
    static let rowBudget: CGFloat = 234

    private static let font = NSFont.systemFont(ofSize: 12)
    /// Rebuilt on every toolbar pass, so the measurements are kept rather than redone.
    private static var widthCache: [String: CGFloat] = [:]

    static func tokenWidth(_ title: String) -> CGFloat {
        if let cached = widthCache[title] { return cached }
        let width = (title as NSString)
            .size(withAttributes: [.font: font]).width.rounded(.up) + tokenChrome
        widthCache[title] = width
        return width
    }

    static func rowWidth(titles: [String], withCounter: Bool) -> CGFloat {
        var pieces = titles.map(tokenWidth)
        if withCounter { pieces.append(counterWidth) }
        guard !pieces.isEmpty else { return 0 }
        return pieces.reduce(0, +) + spacing * CGFloat(pieces.count - 1)
    }

    /// How many of `titles` keep their labels. The rest belong behind the counter.
    ///
    /// Never zero while there is a filter: a row showing only "+7" names nothing at all, which
    /// tells the user less than one overflowing token would.
    static func visibleCount(titles: [String], budget: CGFloat) -> Int {
        guard !titles.isEmpty else { return 0 }
        var used: CGFloat = 0
        for (index, title) in titles.enumerated() {
            let width = tokenWidth(title) + (index == 0 ? 0 : spacing)
            // Taking this one and leaving others behind means the counter has to fit as well.
            let leavesRemainder = index < titles.count - 1
            let allowance = budget - (leavesRemainder ? counterWidth + spacing : 0)
            guard used + width <= allowance else { return max(1, index) }
            used += width
        }
        return titles.count
    }
}

struct ActiveFilterTokens: View {
    @Binding var filters: SearchFilters

    @State private var showOverflow = false

    var body: some View {
        let active = activeFilters
        let shown = FilterTokenLayout.visibleCount(titles: active.map(\.title),
                                                   budget: FilterTokenLayout.rowBudget)
        let hidden = Array(active.dropFirst(shown))

        HStack(spacing: FilterTokenLayout.spacing) {
            ForEach(active.prefix(shown)) { filter in
                FilterToken(title: filter.title, symbol: filter.symbol,
                            icon: filter.icon, remove: filter.remove)
            }
            if !hidden.isEmpty {
                overflowChip(hidden)
            }
        }
    }

    /// Every active filter as one list, in the order the row draws them: types, then apps by name,
    /// then the date. Flattened so the overflow arithmetic sees one sequence rather than three.
    private var activeFilters: [ActiveFilter] {
        var all = FilterType.allCases.filter { filters.types.contains($0) }.map { type in
            ActiveFilter(id: "type:\(type.rawValue)", title: type.title, symbol: type.symbol,
                         icon: nil) { filters.toggle(type) }
        }
        all += sortedApps.map { app in
            ActiveFilter(id: "app:\(app.bundleID)", title: app.name, symbol: nil,
                         icon: app.icon) { filters.toggle(app: app.bundleID) }
        }
        if let date = filters.date {
            all.append(ActiveFilter(id: "date", title: date.title, symbol: "calendar",
                                    icon: nil) { filters.toggle(date: date) })
        }
        return all
    }

    /// Stands in for the filters that did not fit. Tapping it lists them, each still removable —
    /// the row would otherwise be the only way to take one off.
    private func overflowChip(_ hidden: [ActiveFilter]) -> some View {
        Button { showOverflow.toggle() } label: {
            HStack(spacing: 2) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("\(hidden.count)")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(hidden.count) more filter\(hidden.count == 1 ? "" : "s")")
        .fixedSize()
        .popover(isPresented: $showOverflow, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(hidden) { filter in
                    FilterToken(title: filter.title, symbol: filter.symbol,
                                icon: filter.icon, remove: filter.remove)
                }
            }
            .padding(10)
        }
    }

    private var sortedApps: [FilterApp] {
        let resolver = AppNameResolver.shared
        return filters.apps
            .map { FilterApp(bundleID: $0, name: resolver.name(for: $0) ?? $0, icon: resolver.icon(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// One active filter, whatever kind it came from, so the row can measure and slice them together.
private struct ActiveFilter: Identifiable {
    let id: String
    let title: String
    let symbol: String?
    let icon: NSImage?
    let remove: () -> Void
}

private struct FilterToken: View {
    let title: String
    let symbol: String?
    let icon: NSImage?
    let remove: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                if hovered {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 14, height: 14)
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10))
                        .frame(width: 14, height: 14)
                }
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovered ? 0.22 : 0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Remove this filter")
        .fixedSize()
    }
}

/// A single toggleable pill. Selected chips take the accent colour so several active filters
/// read at a glance, which is the whole reason for a popover over a typed query.
private struct FilterChip: View {
    let title: String
    var symbol: String? = nil
    var icon: NSImage? = nil
    let isOn: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .frame(width: 16)
                }
                Text(title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isOn ? Color.accentColor
                          : Color.primary.opacity(hovered ? 0.14 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
    }
}
