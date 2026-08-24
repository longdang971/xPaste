import Foundation

/// Builds the single string a multi-card selection pastes as.
///
/// Lives outside the view so the rule — what each kind of item contributes, what the items are
/// joined with, when a "multi" paste isn't one at all — is unit-testable without a pasteboard.
enum MultiPaste {
    enum Separator: String {
        case newline, space, comma

        var text: String {
            switch self {
            case .newline: return "\n"
            case .space:   return " "
            case .comma:   return ", "
            }
        }

        static func stored(_ defaults: UserDefaults = .standard) -> Separator {
            Separator(rawValue: defaults.string(forKey: "multiPasteSeparator") ?? "") ?? .newline
        }
    }

    /// What one item contributes to a joined paste, or nil when it has nothing to contribute.
    ///
    /// An image has no text worth pasting: it goes in under the name the user gave it, or it is
    /// left out — pasting the literal word "Image" would be worse than pasting nothing.
    static func text(for item: ClipboardItem) -> String? {
        switch item.type {
        case .text, .url, .color:
            return item.text ?? item.displayText
        case .file, .folder:
            return item.fileURLs?.map(\.path).joined(separator: "\n") ?? item.displayText
        case .image:
            return item.label
        }
    }

    /// The joined text for `items`, or nil when fewer than two of them can contribute — in which
    /// case the caller should fall back to a normal single paste, which can still carry an image
    /// or a real file rather than text.
    static func joinedText(for items: [ClipboardItem], separator: Separator) -> String? {
        guard items.count > 1 else { return nil }
        let parts = items.compactMap(text(for:))
        guard parts.count > 1 else { return nil }
        return parts.joined(separator: separator.text)
    }
}
