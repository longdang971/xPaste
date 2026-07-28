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
    let apps: [FilterApp]

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
struct ActiveFilterTokens: View {
    @Binding var filters: SearchFilters

    var body: some View {
        HStack(spacing: 5) {
            ForEach(FilterType.allCases.filter { filters.types.contains($0) }) { type in
                token(title: type.title, symbol: type.symbol) { filters.toggle(type) }
            }
            ForEach(sortedApps, id: \.bundleID) { app in
                token(title: app.name, icon: app.icon) { filters.toggle(app: app.bundleID) }
            }
            if let date = filters.date {
                token(title: date.title, symbol: "calendar") { filters.toggle(date: date) }
            }
        }
    }

    private var sortedApps: [FilterApp] {
        let resolver = AppNameResolver.shared
        return filters.apps
            .map { FilterApp(bundleID: $0, name: resolver.name(for: $0) ?? $0, icon: resolver.icon(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func token(title: String, symbol: String? = nil, icon: NSImage? = nil,
                       remove: @escaping () -> Void) -> some View {
        FilterToken(title: title, symbol: symbol, icon: icon, remove: remove)
    }
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
