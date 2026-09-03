import Foundation

/// A filter the search box offers for what has been typed so far: "to" offers Today, "chr" offers
/// Chrome, "im" offers Image.
///
/// The filter sheet is the only way to narrow the history today, and it costs two clicks and a
/// read of three sections to find one name. Typing that name is faster, and it is what the field
/// already looks like it should accept — filters are drawn as tokens inside it.
struct FilterSuggestion: Identifiable, Equatable {
    /// The apps a query can name. Just the two strings: the suggestion list is rebuilt on every
    /// keystroke, and resolving an icon per app there would put LaunchServices in the middle of
    /// typing. The rows fetch the icons they actually draw.
    struct App: Equatable {
        let bundleID: String
        let name: String
    }

    enum Target: Equatable {
        case type(FilterType)
        case app(bundleID: String)
        case date(DateFilter)
    }

    let target: Target
    let title: String
    /// SF Symbol for types and dates. Apps draw their own icon instead, so nil there.
    let symbol: String?
    /// Where what was typed sits inside `title`, in characters, so the row can draw that part
    /// bright and the rest dim — the whole point of the list is showing what the query became.
    let matchOffset: Int
    let matchLength: Int

    var id: String {
        switch target {
        case .type(let type): return "type:\(type.rawValue)"
        case .app(let bundleID): return "app:\(bundleID)"
        case .date(let date): return "date:\(date.rawValue)"
        }
    }

    var bundleID: String? {
        if case .app(let id) = target { return id }
        return nil
    }

    /// Turns the suggestion into the filter it stands for. Types and apps accumulate; the date is
    /// single-choice, as `SearchFilters` has it everywhere else.
    func apply(to filters: inout SearchFilters) {
        switch target {
        case .type(let type):    filters.types.insert(type)
        case .app(let bundleID): filters.apps.insert(bundleID)
        case .date(let date):    filters.date = date
        }
    }
}

extension FilterSuggestion {
    /// As many as the dropdown shows. Five rows is the most that fits under the field without the
    /// list covering the first row of cards it is meant to be narrowing.
    static let limit = 5

    /// Every filter whose name begins with `query` — at the front of the name, or at the front of
    /// one of its words, so "week" finds "Last week" and "chrome" finds "Google Chrome".
    ///
    /// Filters already applied are left out: the list is what Return would add, and adding one
    /// twice does nothing. Names that start with the query come before names that merely have a
    /// word starting with it, whichever section each came from — a closer match is a better answer
    /// than a tidy grouping.
    static func matching(query: String, apps: [App], active: SearchFilters) -> [FilterSuggestion] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }

        var found: [FilterSuggestion] = []

        for type in FilterType.allCases where !active.types.contains(type) {
            if let hit = match(needle, in: type.title) {
                found.append(FilterSuggestion(target: .type(type), title: type.title,
                                              symbol: type.symbol,
                                              matchOffset: hit.offset, matchLength: hit.length))
            }
        }
        for app in apps where !active.apps.contains(app.bundleID) {
            if let hit = match(needle, in: app.name) {
                found.append(FilterSuggestion(target: .app(bundleID: app.bundleID), title: app.name,
                                              symbol: nil,
                                              matchOffset: hit.offset, matchLength: hit.length))
            }
        }
        for date in DateFilter.allCases where active.date != date {
            if let hit = match(needle, in: date.title) {
                found.append(FilterSuggestion(target: .date(date), title: date.title,
                                              symbol: "calendar",
                                              matchOffset: hit.offset, matchLength: hit.length))
            }
        }

        // Sorted by how early the match sits, and by the order they were collected in for ties.
        // Swift's sort is not stable, so the index carries that order rather than being assumed.
        return found.enumerated()
            .sorted { ($0.element.matchOffset, $0.offset) < ($1.element.matchOffset, $1.offset) }
            .prefix(limit)
            .map(\.element)
    }

    /// The apps `items` were copied from, named and sorted, ready to be matched against.
    static func apps(in items: [ClipboardItem], name: (String) -> String?) -> [App] {
        Set(items.compactMap(\.sourceAppBundleID))
            .map { App(bundleID: $0, name: name($0) ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Where `needle` starts a word of `title`, in characters, or nil.
    ///
    /// The match is anchored at each word start rather than searched for anywhere: "at" should not
    /// offer Text on the strength of the middle of the word, or every second keystroke would put a
    /// list of unrelated filters under the field.
    private static func match(_ needle: String, in title: String) -> (offset: Int, length: Int)? {
        let options: String.CompareOptions = [.anchored, .caseInsensitive, .diacriticInsensitive]
        for start in wordStarts(of: title) {
            guard let range = title.range(of: needle, options: options,
                                          range: start..<title.endIndex) else { continue }
            return (title.distance(from: title.startIndex, to: range.lowerBound),
                    title.distance(from: range.lowerBound, to: range.upperBound))
        }
        return nil
    }

    private static func wordStarts(of title: String) -> [String.Index] {
        var starts = [title.startIndex]
        var index = title.startIndex
        while index < title.endIndex {
            if title[index] == " " {
                let next = title.index(after: index)
                if next < title.endIndex { starts.append(next) }
            }
            index = title.index(after: index)
        }
        return starts
    }
}
