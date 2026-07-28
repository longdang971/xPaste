import Foundation

/// A parsed search box query: `img:`-style type filters, `app:` source filters and free text.
///
/// Written as a value type with no store/UI dependencies so the whole grammar is unit-testable.
/// Unknown `foo:bar` tokens are deliberately left in the free text — the search box is also how
/// people look for strings that happen to contain a colon (URLs, timestamps, code).
struct SearchQuery {
    /// Empty means "any type".
    var types: Set<ClipboardContentType> = []
    /// Every entry must match the item's source app (all-of, so `app:goo app:chr` finds nothing).
    var appTerms: [String] = []
    /// Free text, matched as one substring exactly like the old plain-text search.
    var text: String = ""

    var isEmpty: Bool { types.isEmpty && appTerms.isEmpty && text.isEmpty }

    private static let typeAliases: [String: ClipboardContentType] = [
        "img": .image, "image": .image, "photo": .image,
        "url": .url, "link": .url,
        "text": .text, "txt": .text,
        "file": .file, "doc": .file,
        "folder": .folder, "dir": .folder,
    ]

    static func parse(_ raw: String) -> SearchQuery {
        var query = SearchQuery()
        var freeTokens: [String] = []

        for token in raw.split(separator: " ", omittingEmptySubsequences: true) {
            let token = String(token)
            guard let colon = token.firstIndex(of: ":") else {
                freeTokens.append(token)
                continue
            }
            let key = token[token.startIndex..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])

            if let type = typeAliases[key], value.isEmpty {
                query.types.insert(type)
                continue
            }
            if key == "type", let type = typeAliases[value.lowercased()] {
                query.types.insert(type)
                continue
            }
            if key == "app", !value.isEmpty {
                query.appTerms.append(value)
                continue
            }
            freeTokens.append(token)
        }

        query.text = freeTokens.joined(separator: " ")
        return query
    }

    /// `appName` resolves a bundle ID to its display name; injected so tests don't need
    /// LaunchServices and so the caller controls the cache.
    func matches(_ item: ClipboardItem, appName: (String) -> String?) -> Bool {
        if !types.isEmpty, !types.contains(item.type) { return false }

        if !appTerms.isEmpty {
            guard let bundleID = item.sourceAppBundleID else { return false }
            let name = appName(bundleID)
            for term in appTerms {
                let hitsBundle = bundleID.localizedCaseInsensitiveContains(term)
                let hitsName = name?.localizedCaseInsensitiveContains(term) ?? false
                if !hitsBundle && !hitsName { return false }
            }
        }

        guard !text.isEmpty else { return true }
        return matchesText(item)
    }

    /// Everything free text is matched against, checked one field at a time and bailing on the
    /// first hit. Deliberately allocation-free: this runs for every item on every keystroke, and
    /// gathering the fields into an array first was measurably the expensive half of a search.
    ///
    /// `label` and `ocrText` are what make a renamed snippet and a screenshot findable at all —
    /// neither appears in the item's own text.
    private func matchesText(_ item: ClipboardItem) -> Bool {
        if let label = item.label, label.localizedCaseInsensitiveContains(text) { return true }
        if let ocr = item.ocrText, ocr.localizedCaseInsensitiveContains(text) { return true }
        switch item.type {
        case .text, .url:
            if let body = item.text, body.localizedCaseInsensitiveContains(text) { return true }
        case .image:
            // Nothing else to match on: an image is findable by its name or by the text OCR
            // read out of it, both checked above.
            break
        case .file, .folder:
            // The full path covers the file name too, so there is no need to also build and
            // scan `displayText`, which joins the components into a fresh string every call.
            if let urls = item.fileURLs,
               urls.contains(where: { $0.path.localizedCaseInsensitiveContains(text) }) {
                return true
            }
        }
        return false
    }
}
