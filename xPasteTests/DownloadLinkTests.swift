import XCTest
import UniformTypeIdentifiers
@testable import xPaste

/// A copied link to a file — a GitHub release asset, a PDF, a disk image — is shown under the
/// file's name with its type's icon, and is described from its headers without its body being
/// downloaded.
final class DownloadLinkTests: XCTestCase {

    // MARK: - What counts as a download

    func test_non_html_types_are_downloads() {
        XCTAssertTrue(LinkPreviewService.isDownload(mimeType: "application/octet-stream", contentDisposition: nil))
        XCTAssertTrue(LinkPreviewService.isDownload(mimeType: "application/zip", contentDisposition: nil))
        XCTAssertTrue(LinkPreviewService.isDownload(mimeType: "application/pdf", contentDisposition: nil))
        XCTAssertTrue(LinkPreviewService.isDownload(mimeType: "text/plain", contentDisposition: nil),
                      "a raw script or README is a file, not a page with a title")
    }

    func test_pages_and_pictures_are_not_downloads() {
        XCTAssertFalse(LinkPreviewService.isDownload(mimeType: "text/html", contentDisposition: nil))
        XCTAssertFalse(LinkPreviewService.isDownload(mimeType: "application/xhtml+xml", contentDisposition: nil))
        XCTAssertFalse(LinkPreviewService.isDownload(mimeType: "image/png", contentDisposition: "attachment"),
                       "a picture previews as itself even when it is sent as an attachment")
        XCTAssertFalse(LinkPreviewService.isDownload(mimeType: nil, contentDisposition: nil),
                       "no declared type is read as a page, as before")
    }

    func test_attachment_makes_even_html_a_download() {
        XCTAssertTrue(LinkPreviewService.isDownload(mimeType: "text/html",
                                                    contentDisposition: "attachment; filename=report.html"))
        XCTAssertFalse(LinkPreviewService.isDownload(mimeType: "text/html",
                                                     contentDisposition: "inline"))
    }

    // MARK: - Content-Disposition

    private func name(_ header: String?) -> String? {
        LinkPreviewService.fileName(fromContentDisposition: header)
    }

    func test_plain_and_quoted_filenames() {
        // Exactly what GitHub's asset host sends for the EVKey link.
        XCTAssertEqual(name("attachment; filename=EVKeyMac.zip"), "EVKeyMac.zip")
        XCTAssertEqual(name("attachment; filename=\"EVKey Mac.zip\""), "EVKey Mac.zip")
        XCTAssertEqual(name("attachment; FILENAME = \"a.dmg\""), "a.dmg", "keys are case-insensitive")
        XCTAssertEqual(name("attachment; filename=\"a;b.zip\"; size=3"), "a;b.zip",
                       "a semicolon inside quotes does not split the parameter")
        XCTAssertEqual(name("attachment; filename=\"say \\\"hi\\\".txt\""), "say \"hi\".txt")
    }

    func test_extended_filename_wins_and_is_decoded() {
        XCTAssertEqual(name("attachment; filename=\"fallback.zip\"; filename*=UTF-8''B%E1%BA%A3n%20g%E1%BB%91c.zip"),
                       "Bản gốc.zip")
        XCTAssertEqual(name("attachment; filename*=utf-8'vi'M%C3%A1y.pdf; filename=x.pdf"), "Máy.pdf",
                       "order does not matter")
    }

    func test_raw_utf8_read_as_latin1_is_repaired() {
        // What Foundation hands back for `filename="Máy.zip"` sent as raw UTF-8 bytes.
        let mangled = String(String.UnicodeScalarView("Máy.zip".utf8.map { Unicode.Scalar($0) }))
        XCTAssertNotEqual(mangled, "Máy.zip")
        XCTAssertEqual(name("attachment; filename=\"\(mangled)\""), "Máy.zip")
        XCTAssertEqual(name("attachment; filename=\"café.zip\""), "café.zip",
                       "genuine Latin-1 that is not valid UTF-8 is left alone")
    }

    func test_paths_are_cut_to_their_last_component() {
        XCTAssertEqual(name("attachment; filename=\"../../etc/passwd\""), "passwd")
        XCTAssertEqual(name("attachment; filename=\"C:\\\\Users\\\\a\\\\setup.exe\""), "setup.exe")
    }

    func test_no_filename_means_nil() {
        XCTAssertNil(name(nil))
        XCTAssertNil(name("attachment"))
        XCTAssertNil(name("attachment; filename=\"\""))
        XCTAssertNil(name("inline; filename=  "))
    }

    // MARK: - The name shown

    func test_header_name_beats_the_url() {
        let requested = URL(string: "https://github.com/lamquangminh/EVKey/releases/download/Release/EVKeyMac.zip")!
        let final = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/131986042/25f862de-6590?sig=x")!
        XCTAssertEqual(LinkPreviewService.downloadName(contentDisposition: "attachment; filename=Other.zip",
                                                       requested: requested, final: final), "Other.zip")
    }

    func test_without_a_header_a_component_with_an_extension_wins() {
        let requested = URL(string: "https://example.com/download?id=42")!
        let final = URL(string: "https://cdn.example.com/files/Setup%20V2.dmg")!
        XCTAssertEqual(LinkPreviewService.downloadName(contentDisposition: nil, requested: requested, final: final),
                       "Setup V2.dmg", "decoded, and taken from where the redirects ended")

        let named = URL(string: "https://example.com/files/tool.pkg")!
        let opaque = URL(string: "https://cdn.example.com/blob/abc123")!
        XCTAssertEqual(LinkPreviewService.downloadName(contentDisposition: nil, requested: named, final: opaque),
                       "tool.pkg")
    }

    func test_without_any_extension_the_copied_url_names_it() {
        let requested = URL(string: "https://example.com/download")!
        XCTAssertEqual(LinkPreviewService.downloadName(contentDisposition: nil, requested: requested,
                                                       final: URL(string: "https://cdn.example.com/abc")!),
                       "download")
        XCTAssertNil(LinkPreviewService.downloadName(contentDisposition: nil,
                                                     requested: URL(string: "https://example.com/")!,
                                                     final: nil),
                     "nil leaves the caller to fall back to the host")
    }

    // MARK: - Icon type

    func test_icon_type_comes_from_the_extension_before_the_mime_type() {
        XCTAssertEqual(ClipboardItemCard.downloadIconType(fileName: "EVKeyMac.zip",
                                                          mimeType: "application/octet-stream"), .zip)
        XCTAssertEqual(ClipboardItemCard.downloadIconType(fileName: "report", mimeType: "application/pdf"), .pdf)
        XCTAssertEqual(ClipboardItemCard.downloadIconType(fileName: nil, mimeType: nil), .data)
    }

    // MARK: - The fetch stops where its plan says

    private func fetcher() -> BoundedFetch {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return BoundedFetch(configuration: config)
    }

    private func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://stub.test/\(path)")!)
    }

    func test_a_download_is_answered_from_its_headers_without_reading_the_body() async throws {
        StubProtocol.serve("big.zip", headers: ["Content-Type": "application/octet-stream",
                                                "Content-Disposition": "attachment; filename=big.zip",
                                                "Content-Length": "\(200 * 64 * 1024)"],
                           chunks: 200, chunkSize: 64 * 1024)

        let result = await fetcher().fetch(request("big.zip"), plan: LinkPreviewService.plan(for:))

        let r = try XCTUnwrap(result)
        XCTAssertTrue(r.data.isEmpty)
        XCTAssertEqual(r.response.value(forHTTPHeaderField: "Content-Disposition"), "attachment; filename=big.zip")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThan(StubProtocol.chunksSent("big.zip"), 20,
                          "the transfer was cancelled rather than run to the end")
    }

    func test_a_page_is_read_up_to_its_head_and_no_further() async throws {
        let head = Data("<html><head><title>T</title></head>".utf8)
        StubProtocol.serve("page", headers: ["Content-Type": "text/html"],
                           first: head, chunks: 200, chunkSize: 64 * 1024)

        let result = await fetcher().fetch(request("page"), plan: LinkPreviewService.plan(for:))

        XCTAssertEqual(try XCTUnwrap(result).data, head)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThan(StubProtocol.chunksSent("page"), 20)
    }

    func test_a_head_closer_split_across_chunks_is_still_found() async throws {
        StubProtocol.serve("split", headers: ["Content-Type": "text/html"],
                           firstChunks: [Data("<head>x</he".utf8), Data("ad><body>".utf8)])
        let result = await fetcher().fetch(request("split"), plan: LinkPreviewService.plan(for:))
        XCTAssertEqual(String(decoding: try XCTUnwrap(result).data, as: UTF8.self), "<head>x</head>")
    }

    func test_a_body_over_a_rejecting_cap_is_refused() async {
        StubProtocol.serve("huge.png", headers: ["Content-Type": "image/png"], chunks: 10, chunkSize: 1024)
        let result = await fetcher().fetch(request("huge.png")) { _ in
            .body(cap: 4096, stopAfter: [], overflow: .reject)
        }
        XCTAssertNil(result)
    }

    func test_a_body_over_a_truncating_cap_is_cut_to_it() async throws {
        StubProtocol.serve("long", headers: ["Content-Type": "text/html"], chunks: 10, chunkSize: 1024)
        let result = await fetcher().fetch(request("long")) { _ in
            .body(cap: 4096, stopAfter: [], overflow: .truncate)
        }
        XCTAssertEqual(try XCTUnwrap(result).data.count, 4096)
    }

    // MARK: - Pages that only preview bots get a title from

    private func service() -> LinkPreviewService {
        LinkPreviewService(fetcher: fetcher(), cacheDir: nil)
    }

    private let emptyShell = Data("<html><head><script src=app.js></script></head><body></body>".utf8)
    private let botPage = Data("<html><head><meta property=\"og:title\" content=\"Hoá chất IPA\"><meta property=\"og:image\" content=\"https://cdn.test/p.jpg\"></head>".utf8)
    private let html = ["Content-Type": "text/html; charset=utf-8"]

    func test_a_page_with_nothing_for_the_browser_is_asked_again_as_a_preview_bot() async throws {
        // A Shopee short link, as measured: an empty script shell for a browser, the tags for
        // Twitterbot. Not covered here: live, the second request came back from `URLCache` with
        // the browser's shell until it was told to ignore the cache. `URLCache` does not store
        // what a stub `URLProtocol` serves, so that was checked by A/B against the real link.
        StubProtocol.serve("spa", headers: html, first: emptyShell)
        StubProtocol.serve("spa", toUserAgent: LinkPreviewService.crawlerUA, headers: html, body: botPage)

        let fetched = await service().fetchMetadata(URL(string: "https://stub.test/spa")!)
        let meta = try XCTUnwrap(fetched)

        XCTAssertEqual(meta.title, "Hoá chất IPA")
        XCTAssertEqual(meta.imageURL?.absoluteString, "https://cdn.test/p.jpg")
        XCTAssertEqual(StubProtocol.requestCount("spa"), 2)
    }

    func test_a_page_with_a_title_is_asked_once() async throws {
        StubProtocol.serve("plain", headers: html,
                           first: Data("<html><head><title>Hello</title></head>".utf8))
        let fetched = await service().fetchMetadata(URL(string: "https://stub.test/plain")!)
        let meta = try XCTUnwrap(fetched)
        XCTAssertEqual(meta.title, "Hello")
        XCTAssertEqual(StubProtocol.requestCount("plain"), 1, "a page that answered pays for no second request")
    }

    func test_a_bot_answer_with_nothing_in_it_keeps_the_first_result() async throws {
        StubProtocol.serve("bare", headers: html,
                           first: Data("<html><head><link rel=icon sizes=180x180 href=/i.png></head>".utf8))
        let fetched = await service().fetchMetadata(URL(string: "https://stub.test/bare")!)
        let meta = try XCTUnwrap(fetched)
        XCTAssertNil(meta.title)
        XCTAssertEqual(StubProtocol.requestCount("bare"), 2, "asked once more, and only once more")
    }

    func test_a_non_200_is_nil() async {
        StubProtocol.serve("gone", status: 404, headers: ["Content-Type": "text/html"], chunks: 1, chunkSize: 10)
        let result = await fetcher().fetch(request("gone"), plan: LinkPreviewService.plan(for:))
        XCTAssertNil(result)
    }
}

/// Serves a canned response a chunk at a time, and counts how many chunks went out before the
/// client stopped listening.
final class StubProtocol: URLProtocol {
    private struct Route {
        var status: Int
        var headers: [String: String]
        var leading: [Data]
        var chunks: Int
        var chunkSize: Int
    }

    private static let lock = NSLock()
    private static var routes: [String: Route] = [:]
    private static var sent: [String: Int] = [:]

    static func serve(_ path: String, status: Int = 200, headers: [String: String],
                      first: Data? = nil, firstChunks: [Data] = [],
                      chunks: Int = 0, chunkSize: Int = 0) {
        lock.lock(); defer { lock.unlock() }
        routes[path] = Route(status: status, headers: headers,
                             leading: (first.map { [$0] } ?? []) + firstChunks,
                             chunks: chunks, chunkSize: chunkSize)
        sent[path] = 0
    }

    static func chunksSent(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return sent[path] ?? 0
    }

    /// Routes that answer only a given User-Agent, for sites that serve preview bots a different
    /// page. Checked before the plain route.
    private static var agentRoutes: [String: Route] = [:]

    static func serve(_ path: String, toUserAgent agent: String, headers: [String: String], body: Data) {
        lock.lock(); defer { lock.unlock() }
        agentRoutes[path + "|" + agent] = Route(status: 200, headers: headers, leading: [body],
                                                chunks: 0, chunkSize: 0)
    }

    private static var requests: [String: Int] = [:]

    static func requestCount(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests[path] ?? 0
    }

    private let stopLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = String(request.url!.path.dropFirst())
        let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
        Self.lock.lock()
        let route = Self.agentRoutes[path + "|" + agent] ?? Self.routes[path]
        Self.requests[path, default: 0] += 1
        Self.lock.unlock()
        guard let route else { return }

        let response = HTTPURLResponse(url: request.url!, statusCode: route.status,
                                       httpVersion: "HTTP/1.1", headerFields: route.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        DispatchQueue.global().async {
            for data in route.leading {
                guard !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: data)
                Thread.sleep(forTimeInterval: 0.01)
            }
            for _ in 0..<route.chunks {
                guard !self.isStopped else { return }
                Self.lock.lock(); Self.sent[path, default: 0] += 1; Self.lock.unlock()
                self.client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: route.chunkSize))
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard !self.isStopped else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopLock.lock(); stopped = true; stopLock.unlock()
    }

    private var isStopped: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }
}

