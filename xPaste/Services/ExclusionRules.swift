import Foundation

/// User-defined patterns for content that must never reach the history — API tokens, card
/// numbers, private keys.
///
/// A pattern wrapped in slashes (`/sk-[A-Za-z0-9]{20,}/`) is a regular expression; anything else
/// is a plain case-insensitive substring, which is what most people actually want to type.
enum ExclusionRules {
    static let defaultsKey = "excludedPatterns"

    static func storedPatterns(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    /// Regex matching is capped to this many UTF-16 units. A pathological pattern against a
    /// multi-megabyte paste would otherwise stall the clipboard poll; secrets people want
    /// excluded live at the start of what they copy, not 100k characters in.
    private static let regexScanLimit = 100_000

    static func shouldExclude(_ text: String, patterns: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let body = regexBody(of: trimmed) {
                guard let regex = compiled(body) else { continue }
                let scanned = min(text.utf16.count, regexScanLimit)
                if regex.firstMatch(in: text, range: NSRange(location: 0, length: scanned)) != nil {
                    return true
                }
            } else if text.localizedCaseInsensitiveContains(trimmed) {
                return true
            }
        }
        return false
    }

    /// True when the pattern is syntactically usable, so Settings can reject a bad regex
    /// at the moment it's typed instead of silently never matching.
    static func isValid(_ pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        guard let body = regexBody(of: trimmed) else { return true }
        return compiled(body) != nil
    }

    /// `/…/` → the expression inside; nil for plain substrings.
    private static func regexBody(of pattern: String) -> String? {
        guard pattern.count >= 3, pattern.hasPrefix("/"), pattern.hasSuffix("/") else { return nil }
        return String(pattern.dropFirst().dropLast())
    }

    private static var cache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func compiled(_ body: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[body] { return cached }
        guard let regex = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) else {
            return nil
        }
        cache[body] = regex
        return regex
    }
}
