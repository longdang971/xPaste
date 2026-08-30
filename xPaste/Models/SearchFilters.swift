import Foundation

/// A kind of item as the filter popover presents it. Not a bare synonym for `ClipboardContentType`:
/// the popover calls `.url` "Link", which is the only renaming left once the type — not this
/// filter — decides whether a piece of text is a colour.
enum FilterType: String, CaseIterable, Identifiable {
    case text, link, image, color, file, folder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text:   return "Text"
        case .link:   return "Link"
        case .image:  return "Image"
        case .color:  return "Color"
        case .file:   return "File"
        case .folder: return "Folder"
        }
    }

    var symbol: String {
        switch self {
        case .text:   return "text.alignleft"
        case .link:   return "link"
        case .image:  return "photo"
        case .color:  return "paintpalette"
        case .file:   return "doc"
        case .folder: return "folder"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .text:   return item.type == .text
        case .color:  return item.type == .color
        case .link:   return item.type == .url
        case .image:  return item.type == .image
        case .file:   return item.type == .file
        case .folder: return item.type == .folder
        }
    }
}

/// The date windows the popover offers. Single-choice: "Today" and "Last week" together would
/// mean nothing.
enum DateFilter: String, CaseIterable, Identifiable {
    case today, yesterday, thisWeek, lastWeek, last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:      return "Today"
        case .yesterday:  return "Yesterday"
        case .thisWeek:   return "This week"
        case .lastWeek:   return "Last week"
        case .last30Days: return "Last 30 days"
        }
    }

    /// The window this filter covers, relative to `now`.
    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .today:
            return calendar.dateInterval(of: .day, for: now)
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .day, for: yesterday)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
        case .lastWeek:
            guard let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now) else { return nil }
            return calendar.dateInterval(of: .weekOfYear, for: lastWeek)
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return nil }
            return DateInterval(start: start, end: now)
        }
    }

    func matches(_ item: ClipboardItem, now: Date, calendar: Calendar) -> Bool {
        guard let interval = interval(now: now, calendar: calendar) else { return true }
        return interval.contains(item.timestamp)
    }
}

/// What the filter popover has switched on. Within a section the choices are OR-ed (Image *or*
/// Link); across sections they are AND-ed (an Image **from Chrome** **today**).
struct SearchFilters: Equatable {
    var types: Set<FilterType> = []
    /// Source app bundle IDs.
    var apps: Set<String> = []
    var date: DateFilter?

    var isEmpty: Bool { types.isEmpty && apps.isEmpty && date == nil }

    mutating func toggle(_ type: FilterType) {
        if types.contains(type) { types.remove(type) } else { types.insert(type) }
    }

    mutating func toggle(app bundleID: String) {
        if apps.contains(bundleID) { apps.remove(bundleID) } else { apps.insert(bundleID) }
    }

    mutating func toggle(date value: DateFilter) {
        date = (date == value) ? nil : value
    }

    mutating func clear() { self = SearchFilters() }

    /// Drops the token a Backspace in the search field should remove: the last one shown, which
    /// is the date, then the trailing app, then the trailing type — the order `ActiveFilterTokens`
    /// draws them in. `appName` resolves bundle IDs so the app order matches what is on screen.
    mutating func removeLastToken(appName: (String) -> String?) {
        if date != nil {
            date = nil
            return
        }
        let lastApp = apps
            .map { (id: $0, name: appName($0) ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .last
        if let lastApp {
            apps.remove(lastApp.id)
            return
        }
        if let lastType = FilterType.allCases.last(where: { types.contains($0) }) {
            types.remove(lastType)
        }
    }

    func matches(_ item: ClipboardItem,
                 now: Date = Date(),
                 calendar: Calendar = .current) -> Bool {
        if !types.isEmpty, !types.contains(where: { $0.matches(item) }) { return false }
        if !apps.isEmpty {
            guard let bundleID = item.sourceAppBundleID, apps.contains(bundleID) else { return false }
        }
        if let date, !date.matches(item, now: now, calendar: calendar) { return false }
        return true
    }
}
