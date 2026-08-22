import Foundation

/// Text rewrites offered by a card's "Paste as…" submenu.
///
/// Pure string→string so the whole set is unit-testable without a pasteboard. Which cases are
/// offered for a given item is decided by `applicable(to:type:)` — a JSON entry on a shopping
/// list, or "Domain only" on a plain paragraph, is noise rather than a feature.
enum TextTransform: String, CaseIterable {
    case trimWhitespace
    case singleLine
    case lowercase
    case uppercase
    case capitalized
    case prettyJSON
    case minifyJSON
    case urlDecode
    case urlEncode
    case domainOnly

    var title: String {
        switch self {
        case .trimWhitespace: return "Trimmed"
        case .singleLine:     return "Single Line"
        case .lowercase:      return "lowercase"
        case .uppercase:      return "UPPERCASE"
        case .capitalized:    return "Capitalized"
        case .prettyJSON:     return "Pretty JSON"
        case .minifyJSON:     return "Minified JSON"
        case .urlDecode:      return "URL Decoded"
        case .urlEncode:      return "URL Encoded"
        case .domainOnly:     return "Domain Only"
        }
    }

    var symbol: String {
        switch self {
        case .trimWhitespace: return "scissors"
        case .singleLine:     return "arrow.left.and.right"
        case .lowercase:      return "textformat.abc"
        case .uppercase:      return "textformat.abc.dottedunderline"
        case .capitalized:    return "textformat"
        case .prettyJSON:     return "curlybraces"
        case .minifyJSON:     return "curlybraces.square"
        case .urlDecode:      return "percent"
        case .urlEncode:      return "percent"
        case .domainOnly:     return "globe"
        }
    }

    /// Returns the rewritten text, or nil when the transform doesn't apply to this input
    /// (malformed JSON, a string with no host, …) so callers can drop the menu entry.
    func apply(to text: String) -> String? {
        switch self {
        case .trimWhitespace:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)

        case .singleLine:
            let joined = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return joined.isEmpty ? nil : joined

        case .lowercase:
            return text.lowercased()

        case .uppercase:
            return text.uppercased()

        case .capitalized:
            return text.capitalized

        case .prettyJSON, .minifyJSON:
            guard let object = Self.jsonObject(in: text) else { return nil }
            var options: JSONSerialization.WritingOptions = self == .prettyJSON ? [.prettyPrinted] : []
            options.insert(.withoutEscapingSlashes)
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: options),
                  let out = String(data: data, encoding: .utf8)
            else { return nil }
            return out

        case .urlDecode:
            guard let decoded = text.removingPercentEncoding, decoded != text else { return nil }
            return decoded

        case .urlEncode:
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed),
                  encoded != text
            else { return nil }
            return encoded

        case .domainOnly:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = URL(string: trimmed)?.host, !host.isEmpty else { return nil }
            return host
        }
    }

    /// The transforms worth showing for this text, in menu order.
    static func applicable(to text: String, type: ClipboardContentType) -> [TextTransform] {
        guard type == .text || type == .url else { return [] }
        return allCases.filter { transform in
            guard let result = transform.apply(to: text) else { return false }
            // A rewrite that changes nothing is a dead menu entry.
            return result != text
        }
    }

    /// Parses `text` as JSON, but only after a cheap first-character check — `JSONSerialization`
    /// on a half-megabyte of prose is pure waste, and this runs while a menu is being built.
    ///
    /// Shared with `SaveFormat`, which decides an item is a `.json` file by the same question this
    /// answers, rather than growing a second JSON parser with its own idea of the size cap.
    private static let jsonSizeLimit = 4_000_000
    static func jsonObject(in text: String) -> Any? {
        guard text.utf8.count <= jsonSizeLimit else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let data = trimmed.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
