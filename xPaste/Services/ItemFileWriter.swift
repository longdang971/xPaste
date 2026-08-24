import Foundation

/// Puts a `SaveFormat.Suggestion` on disk.
///
/// The one place in saving that touches the filesystem, kept apart from the decision it carries out
/// so that decision can be tested without a directory and this can be tested without a dialog.
enum ItemFileWriter {

    enum Failure: LocalizedError {
        /// The item outlived its content, so there is nothing to write. Reported rather than
        /// written as an empty file, which the user would only discover was empty later.
        case noContent
        /// A page that was never fetched reached the write. `resolving` is what fetches it.
        case unresolvedPage

        var errorDescription: String? {
            switch self {
            case .noContent:
                return "This item’s content is no longer available to save."
            case .unresolvedPage:
                return "The page was not downloaded before saving."
            }
        }
    }

    /// Turns anything that is not bytes yet into bytes.
    ///
    /// Only a Link needs this, and only because the page it names lives somewhere else. Kept apart
    /// from `write` so the write stays synchronous and testable without a network, and so the one
    /// slow step is visible at the call site rather than hidden inside a file write.
    static func resolving(_ suggestion: SaveFormat.Suggestion) async throws -> SaveFormat.Suggestion {
        guard case let .remoteHTML(link) = suggestion.payload else { return suggestion }
        let html = try await PageArchive.html(for: link)
        return SaveFormat.Suggestion(baseName: suggestion.baseName,
                                     ext: suggestion.ext,
                                     payload: .data(html))
    }

    static func write(_ suggestion: SaveFormat.Suggestion, to url: URL) throws {
        switch suggestion.payload {
        case .unavailable:
            throw Failure.noContent
        case .remoteHTML:
            throw Failure.unresolvedPage
        case let .text(text):
            var bytes = Data(text.utf8)
            // A document saved out of a text item hits the same trap a saved page does: the bytes
            // are UTF-8, and a browser opening a file that never says so falls back to windows-1252.
            if suggestion.ext == "html" { bytes = HTMLCharset.declaring(bytes, charset: "utf-8") }
            try bytes.write(to: url, options: .atomic)
        case let .data(data):
            try data.write(to: url, options: .atomic)
        }
    }
}
