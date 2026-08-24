import Foundation

/// Fetches the page behind a link so a Link item can be saved as the page rather than as a pointer
/// to it.
///
/// Kept apart from `LinkPreviewService`, which reads only as much of a page as its `<head>` needs
/// and caches the result. This wants the document whole and caches nothing: it runs once, when
/// somebody has already chosen where to put the file.
enum PageArchive {

    /// The largest page worth writing. Well past anything that is really a document; a response
    /// bigger than this is a download that arrived through a link.
    static let byteCap = 20 * 1024 * 1024

    /// Matches what `LinkPreviewService` sends. Some sites serve a different document, or none at
    /// all, to a client that does not look like a browser.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    enum Failure: LocalizedError {
        case unreachable(status: Int)
        case tooLarge(bytes: Int)
        case empty

        var errorDescription: String? {
            switch self {
            case let .unreachable(status):
                return "The page could not be downloaded (HTTP \(status))."
            case let .tooLarge(bytes):
                return "The page is too large to save (\(bytes / 1_000_000) MB)."
            case .empty:
                return "The page returned nothing to save."
            }
        }
    }

    /// The page at `url`, as served.
    ///
    /// What lands on disk is the markup and nothing else — no images, no stylesheets, no script
    /// results. A page that builds itself in the browser saves as the shell it was served as.
    ///
    /// One byte-for-byte exception, and only for pages that need it: a document whose encoding was
    /// declared in the `Content-Type` header rather than in its own markup has that declaration
    /// written into it before it is handed on, because the header does not survive being saved.
    /// See `HTMLCharset`.
    static func html(for url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.unreachable(status: http.statusCode)
        }
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= byteCap else { throw Failure.tooLarge(bytes: data.count) }
        return HTMLCharset.declaring(data, charset: (response as? HTTPURLResponse)?.textEncodingName)
    }
}
