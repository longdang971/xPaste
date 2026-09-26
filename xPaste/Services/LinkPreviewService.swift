import Foundation
import AppKit

struct LinkPreviewData {
    let title: String?
    let imageURL: URL?
    let image: NSImage?
    let domain: String?
    /// The URL named a picture rather than a page. The card draws the picture itself instead of
    /// treating it as a scraped `og:image`, which is what decides whether it may be shrunk to a
    /// logo: a link to a small or square photograph is still a photograph.
    var isDirectImage: Bool = false
    /// The URL named a file to download rather than a page. `title` is then the file's name and
    /// the card draws the system icon for its type instead of a picture or the site's favicon.
    var isDownload: Bool = false
    /// The download's declared type, which the icon falls back on when its name has no extension.
    var mimeType: String? = nil
}

private struct CachedLinkMeta: Codable {
    let url: URL
    let title: String?
    let imageURL: URL?
    let domain: String?
    var faviconURL: URL?
    /// Every icon the page declares, largest first. Optional for the same reason as the fields
    /// below it: entries written before this existed have to keep decoding.
    var faviconURLs: [URL]?
    // Optional rather than defaulted: synthesised `Codable` has no notion of a property default,
    // so a non-optional here would fail to decode every entry already on disk.
    var isDirectImage: Bool?
    var isDownload: Bool?
    var mimeType: String?
}

actor LinkPreviewService {
    static let shared = LinkPreviewService()

    /// Bounded to the same size as the directory behind it.
    ///
    /// It used to be a plain dictionary that only ever grew: the disk cache was evicted at 200
    /// entries and this was not, so a long session accumulated an entry for every link ever
    /// previewed. `metaOrder` is the insertion order eviction reads.
    private var metaCache: [URL: CachedLinkMeta] = [:]
    private var metaOrder: [URL] = []
    // NSCache (thread-safe, count-bounded) instead of plain dictionaries: the old dict eviction
    // removed `keys.first`, whose order is unspecified, so it could drop the entry just inserted,
    // and neither dict was ever bounded — decoded NSImages leaked for the whole session.
    private let imageCache = NSCache<NSURL, NSImage>()
    private let faviconCache = NSCache<NSString, NSImage>()
    private let maxDiskEntries = 200

    private let cacheDir: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("xPaste/LinkPreviews", isDirectory: true)

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    /// The backstop on how much of a document is decoded into a `String` and run past six regexes.
    ///
    /// A ceiling, not the usual amount: `headSlice` cuts at `</head>` first, so an ordinary page
    /// costs its head and nothing else. This is what a document with no `</head>` in reach falls
    /// back to.
    private static let htmlScanCap = 2 * 1024 * 1024

    /// The part of a document worth scanning: its head.
    ///
    /// It used to be the first 512KB, which is where every YouTube link stopped having a title.
    /// Measured on two videos: `<title>` lands at byte 703,644 and 707,000-odd, `og:image` just
    /// after it, and `</head>` at 712,419 — the 700KB in front of them is inline script. The
    /// regexes found nothing, the card fell to the favicon plate, and the footer printed the URL
    /// twice. github.com puts the same tags at byte 29,181 and vnexpress.net at 2,688, which is
    /// why only YouTube showed it.
    ///
    /// Cutting at `</head>` rather than raising the prefix keeps the bound where it belongs: these
    /// tags are in the head by definition, so scanning exactly the head is both the smallest slice
    /// that can contain them and the largest that could be worth reading. A ten-megabyte page with
    /// an ordinary head now costs less than it did before, not more.
    ///
    /// Only the two spellings real documents use are searched for. A page that closes its head as
    /// `</Head>` gets the ceiling instead, which is what it would have had anyway.
    static func headSlice(of data: Data) -> Data {
        let ceiling = data.prefix(htmlScanCap)
        for needle in headClosers {
            if let found = ceiling.range(of: needle) { return ceiling.prefix(upTo: found.upperBound) }
        }
        return ceiling
    }
    private static let headClosers = [Data("</head>".utf8), Data("</HEAD>".utf8)]

    /// The largest preview picture worth holding. A card draws it at 232pt.
    private static let imageByteCap = 8 * 1024 * 1024

    /// Whether a response is small enough to keep.
    ///
    /// Both halves matter and they answer different questions. `expectedContentLength` is what the
    /// server declared, checked so an oversized body is refused on its header rather than after it
    /// has been decoded into an `NSImage`; `data.count` is what actually arrived, checked because a
    /// server may declare nothing (-1) or declare wrongly.
    ///
    /// What this does *not* do is stop the bytes being received: `URLSession.data(for:)` has
    /// already buffered the whole response by the time it returns. Closing that would mean reading
    /// the body a byte at a time, which every ordinary preview would pay for.
    private static func withinCap(_ response: URLResponse, _ data: Data, cap: Int) -> Bool {
        let declared = response.expectedContentLength
        if declared > 0, declared > Int64(cap) { return false }
        return data.count <= cap
    }

    init() {
        // Cost as well as count, for the same reason as everywhere else pictures are cached: an
        // `og:image` is a full-size cover picture, and fifty of them decoded is not a small number.
        imageCache.countLimit = 50
        imageCache.totalCostLimit = 32 * 1024 * 1024
        faviconCache.countLimit = 100
        faviconCache.totalCostLimit = 4 * 1024 * 1024
        if let dir = cacheDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            Task { await self.loadDiskCache() }
        }
    }

    /// Turn an href / og:image value into a loadable absolute URL. `URL(string:)` succeeds on
    /// path-relative ("/x.png") and protocol-relative ("//cdn/x.png") strings but yields a
    /// scheme-less URL that URLSession can't fetch — so resolve those against the page URL.
    private static func resolvedURL(_ s: String, relativeTo base: URL) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }

    /// Whether a response body is a picture rather than a page.
    ///
    /// Worth checking explicitly because the HTML path cannot fail: `.isoLatin1` maps every byte
    /// to a character, so JPEG bytes decode into a "document" that the `og:` regexes simply find
    /// nothing in — leaving a link card with no title where the picture should be.
    static func isDirectImage(mimeType: String?) -> Bool {
        mimeType?.lowercased().hasPrefix("image/") ?? false
    }

    /// The https twin of an http URL, and any other URL unchanged.
    ///
    /// macOS refuses a plain-http request from an app with no ATS exception before it ever reaches
    /// the network — `NSURLErrorDomain -1022`, measured against a bundle with this app's
    /// `Info.plist` — and `fetchMetadata` swallows that with `try?` like any other failure. So a
    /// link copied as `http://…` came back with no title, no picture and no favicon: the card fell
    /// to the placeholder plate every time, for a page that was perfectly alive.
    ///
    /// Asking for https instead costs one scheme and needs no ATS exception. Nearly every site
    /// with a title worth showing serves it over https as well; one that genuinely does not still
    /// gets the plate, and that is the site ATS is refusing on the user's behalf. The alternative
    /// was `NSAllowsArbitraryLoads`, which turns ATS off for the whole app to fix the preview of a
    /// page whose title and `og:image` a network attacker would then be writing.
    ///
    /// Only the request is rewritten. What the item holds, what gets pasted, and what the card's
    /// footer reads are all still the URL the user copied.
    static func secureTwin(of url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.scheme = "https"
        // `http://host:80/` is the default spelled out. Carried across it names a port nothing
        // serves TLS on, turning a request that would have worked into a refused one.
        if parts.port == 80 { parts.port = nil }
        return parts.url ?? url
    }

    /// How much of a response to read, decided from its headers.
    ///
    /// A picture is read whole or not at all; a page up to the end of its head, which is where
    /// every tag worth reading lives; a download not at all.
    static func plan(for response: HTTPURLResponse) -> BoundedFetch.Plan {
        if isDirectImage(mimeType: response.mimeType) {
            return .body(cap: imageByteCap, stopAfter: [], overflow: .reject)
        }
        if isDownload(mimeType: response.mimeType,
                      contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition")) {
            return .headersOnly
        }
        return .body(cap: htmlScanCap, stopAfter: headClosers, overflow: .truncate)
    }

    /// Whether a response is a file to download rather than a page or a picture.
    ///
    /// A picture never is, even sent as an attachment: it previews better as itself. Past that,
    /// `attachment` says so outright, and otherwise anything that is not HTML is a file — a PDF,
    /// a disk image, a script served as `text/plain`. A response that declares no type at all is
    /// read as a page, which is what the scrape did before this existed.
    static func isDownload(mimeType: String?, contentDisposition: String?) -> Bool {
        if isDirectImage(mimeType: mimeType) { return false }
        if let disposition = contentDisposition?.trimmingCharacters(in: .whitespaces).lowercased(),
           disposition.hasPrefix("attachment") {
            return true
        }
        guard let mime = mimeType?.lowercased() else { return false }
        return mime != "text/html" && mime != "application/xhtml+xml"
    }

    /// The name a download is shown under.
    ///
    /// `Content-Disposition` first, because the URL often has no name in it at all: a GitHub
    /// release link redirects to `release-assets.githubusercontent.com/…/<uuid>?sig=…`, and
    /// `EVKeyMac.zip` exists only in that header. Then whichever URL's last component looks like
    /// a file name — the one copied, then the one the redirects ended on — and then any last
    /// component at all. Nil leaves the caller to fall back to the host.
    static func downloadName(contentDisposition: String?, requested: URL, final: URL?) -> String? {
        if let name = fileName(fromContentDisposition: contentDisposition) { return name }
        let components = [requested, final].compactMap { $0?.lastPathComponent }
            .filter { !$0.isEmpty && $0 != "/" }
        return components.first { !($0 as NSString).pathExtension.isEmpty } ?? components.first
    }

    /// The file name a `Content-Disposition` header carries, or nil if it carries none.
    ///
    /// `filename*` (RFC 5987, `UTF-8''EVKey%20M%C3%A1y.zip`) wins over `filename` when both are
    /// there, as it does in browsers. A plain `filename` sent as raw UTF-8 reaches Foundation as
    /// Latin-1 — a Vietnamese name arrives as `MÃ¡y` — so it is read back as UTF-8 when it can be.
    /// Parameters are split on `;` outside quotes only, so a quoted name may contain one.
    static func fileName(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        var plain: String?
        for parameter in splitParameters(header) {
            guard let eq = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = parameter[parameter.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3,
                   let decoded = String(pieces[2]).removingPercentEncoding,
                   let name = sanitizedFileName(decoded) {
                    return name
                }
            } else if key == "filename" {
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                }
                plain = repairedUTF8(value)
            }
        }
        return plain.flatMap(sanitizedFileName)
    }

    private static func splitParameters(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for ch in header {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quoted { current.append(ch); escaped = true; continue }
            if ch == "\"" { quoted.toggle() }
            if ch == ";" && !quoted { parts.append(current); current = ""; continue }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    /// A string that is really UTF-8 bytes read one per character, read again as UTF-8.
    /// Anything else — plain ASCII, or text that does not decode — comes back unchanged.
    private static func repairedUTF8(_ s: String) -> String {
        let scalars = s.unicodeScalars.map(\.value)
        guard scalars.contains(where: { $0 >= 0x80 }), scalars.allSatisfy({ $0 <= 0xFF }),
              let decoded = String(bytes: scalars.map { UInt8($0) }, encoding: .utf8)
        else { return s }
        return decoded
    }

    /// Only the last path component: a header may send `../../x.zip` or a Windows path.
    private static func sanitizedFileName(_ s: String) -> String? {
        let last = s.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let name = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Whether an entry on disk was written by a version that knew less than this one.
    ///
    /// Only one case so far: a picture link used to be filed with no title, so its card printed the
    /// URL twice. Those entries would keep doing it forever, because the cache is what a card
    /// reads. Refetching one costs a single request, and only for links already previewed.
    private static func isStale(_ meta: CachedLinkMeta) -> Bool {
        meta.isDirectImage == true && meta.title == nil
    }

    func fetchMetadata(_ url: URL) async -> LinkPreviewData? {
        if let cached = metaCache[url], !Self.isStale(cached) {
            return LinkPreviewData(title: cached.title, imageURL: cached.imageURL, image: nil,
                                   domain: cached.domain,
                                   isDirectImage: cached.isDirectImage ?? false,
                                   isDownload: cached.isDownload ?? false,
                                   mimeType: cached.mimeType)
        }

        // The request goes to the https twin; everything below still files the result under the
        // URL the caller asked about, which is the one the item holds. See `secureTwin`.
        let target = Self.secureTwin(of: url)
        var req = URLRequest(url: target, timeoutInterval: 8)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let fetched = await BoundedFetch.shared.fetch(req, plan: Self.plan(for:)) else { return nil }
        let resp = fetched.response
        let data = fetched.data

        let domain = url.host?.replacingOccurrences(of: "www.", with: "")

        // A file to download is described by its headers: the body was never read. Cached like any
        // other result, so the card does not ask again every time it comes on screen.
        let disposition = resp.value(forHTTPHeaderField: "Content-Disposition")
        if Self.isDownload(mimeType: resp.mimeType, contentDisposition: disposition) {
            let name = Self.downloadName(contentDisposition: disposition, requested: url,
                                         final: resp.url) ?? domain
            var meta = CachedLinkMeta(url: url, title: name, imageURL: nil, domain: domain)
            meta.isDownload = true
            meta.mimeType = resp.mimeType
            remember(meta)
            persistToDisk(meta)
            evictDiskIfNeeded()
            return LinkPreviewData(title: name, imageURL: nil, image: nil, domain: domain,
                                   isDownload: true, mimeType: resp.mimeType)
        }

        // A URL that names a picture is its own preview: the image URL is the link itself, and the
        // bytes are already here, so seed the image cache rather than fetch the same file twice.
        // Decodable, not merely declared: an `image/svg+xml` that `NSImage` cannot open falls
        // through to the scrape below and keeps the favicon card it used to get.
        // Already held to `imageByteCap` by the fetch's plan.
        if Self.isDirectImage(mimeType: resp.mimeType),
           let image = NSImage(data: data) {
            imageCache.setObject(image, forKey: url as NSURL, cost: image.approximateDecodedBytes)
            // The file name is the title. A picture has no `og:title` to read, and without one the
            // card's footer printed the whole URL twice — once bold and once grey. `URL` hands the
            // component back decoded, so an escaped name reads as itself rather than as %E1%BA%A2.
            let name = target.lastPathComponent
            var meta = CachedLinkMeta(url: url, title: name.isEmpty ? nil : name,
                                      imageURL: target, domain: domain)
            meta.isDirectImage = true
            remember(meta)
            persistToDisk(meta)
            evictDiskIfNeeded()
            return LinkPreviewData(title: meta.title, imageURL: target, image: nil, domain: domain,
                                   isDirectImage: true)
        }

        // Only the head is of interest. Truncated at a byte count when it has to fall back to the
        // ceiling, so a UTF-8 sequence can be cut in half — the ISO-Latin-1 fallback below decodes
        // whatever UTF-8 rejects, and a mangled tail cannot affect tags inside the head.
        let scanned = Self.headSlice(of: data)
        guard let html = String(data: scanned, encoding: .utf8)
                ?? String(data: scanned, encoding: .isoLatin1)
        else { return nil }

        let title = ogMeta("og:title", in: html) ?? ogMeta("twitter:title", in: html) ?? pageTitle(in: html)
        let imgStr = ogMeta("og:image", in: html) ?? ogMeta("twitter:image", in: html)
        var ogImageURL: URL?
        if let s = imgStr { ogImageURL = Self.resolvedURL(s, relativeTo: target) }
        let favURLs = Self.faviconURLs(in: html, relativeTo: target)

        var meta = CachedLinkMeta(url: url, title: title, imageURL: ogImageURL, domain: domain)
        meta.faviconURL = favURLs.first
        meta.faviconURLs = favURLs
        // Don't cache a fully-empty result — an error/redirect page that still returns HTML
        // would otherwise poison the cache and block a real preview once the site recovers.
        if title != nil || ogImageURL != nil {
            remember(meta)
            persistToDisk(meta)
            evictDiskIfNeeded()
        }

        return LinkPreviewData(title: title, imageURL: ogImageURL, image: nil, domain: domain)
    }

    func fetchImage(for url: URL) async -> NSImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let meta = metaCache[url], let imageURL = meta.imageURL else { return nil }
        // An `og:image` written out as an absolute `http://` URL is refused exactly as the page
        // would have been.
        var req = URLRequest(url: Self.secureTwin(of: imageURL), timeoutInterval: 8)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let (imgData, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              Self.withinCap(resp, imgData, cap: Self.imageByteCap),
              let image = NSImage(data: imgData) else { return nil }

        imageCache.setObject(image, forKey: url as NSURL, cost: image.approximateDecodedBytes)
        return image
    }

    /// Below this, a favicon is too few pixels for the plate a card draws it on and the search
    /// carries on to the next source.
    ///
    /// 64, because the card draws the icon at up to 72pt — 144 device pixels on a 2x display. A
    /// site's own `rel="icon"` is very often 16 or 32, which is where the blurred Drive triangle
    /// came from: a 32-pixel image stretched across 144.
    private static let faviconMinPixels = 64

    /// The services asked for an icon when the page's own is too small, biggest-first.
    ///
    /// Measured against drive.google.com, whose card was the blurred one: its own
    /// `//docs.google.com/favicon.ico` is 32 pixels, Google's older `s2/favicons` hands back 20
    /// whatever `sz` asks for, DuckDuckGo 32 — and `faviconV2` 64. So `faviconV2` goes first and
    /// the other two stay as the fallbacks for a host it does not know.
    private static func faviconServices(for host: String) -> [URL] {
        var v2 = URLComponents(string: "https://t3.gstatic.com/faviconV2")
        v2?.queryItems = [
            URLQueryItem(name: "client", value: "SOCIAL"),
            URLQueryItem(name: "type", value: "FAVICON"),
            URLQueryItem(name: "fallback_opts", value: "TYPE,SIZE,URL"),
            URLQueryItem(name: "size", value: "128"),
            URLQueryItem(name: "url", value: "https://\(host)"),
        ]
        return [
            v2?.url,
            // 128, not the 64 this used to ask for: the card draws at up to 72pt, and asking for
            // the size it draws costs the same request.
            URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128"),
            URL(string: "https://icons.duckduckgo.com/ip3/\(host).ico"),
        ].compactMap { $0 }
    }

    /// The site's icon, taken from whichever source has the most pixels of it.
    ///
    /// Every candidate used to be equal and the first that decoded won — which meant the page's own
    /// `rel="icon"`, the smallest one there is, beat Google's service every time. Now a small one
    /// is kept only as the fallback: the loop stops at the first icon big enough to draw, and
    /// settles for the largest it saw if none of them were.
    func fetchFavicon(for url: URL) async -> NSImage? {
        guard let host = url.host else { return nil }
        if let cached = faviconCache.object(forKey: host as NSString) { return cached }

        let meta = metaCache[url]
        let declared = meta?.faviconURLs ?? meta?.faviconURL.map { [$0] } ?? []

        // What the page says about itself, whatever size it is. A site's own declaration is the
        // only source that is *about* this site; the services are guesses at it, and a guess must
        // never win on size. xxxhay.tv declares a 48-pixel icon, which is under the threshold
        // below, and letting the loop fall through to Google put a black YouTube play button on
        // the card — 128 pixels of the wrong site. Drawing 48 pixels at 48pt is the right answer.
        for favURL in declared {
            if let img = await loadFavicon(favURL) {
                faviconCache.setObject(img, forKey: host as NSString, cost: img.approximateDecodedBytes)
                return img
            }
        }

        // Only now, and here bigger is better: these are all guessing at the same thing, so the
        // one with the most pixels is the best guess.
        var best: NSImage?
        var bestPixels = 0
        for favURL in Self.faviconServices(for: host) {
            guard let img = await loadFavicon(favURL) else { continue }
            let pixels = img.representations.map(\.pixelsWide).max() ?? 0
            if pixels > bestPixels { best = img; bestPixels = pixels }
            if bestPixels >= Self.faviconMinPixels { break }
        }
        if let best {
            faviconCache.setObject(best, forKey: host as NSString, cost: best.approximateDecodedBytes)
        }
        return best
    }

    private func loadFavicon(_ url: URL) async -> NSImage? {
        var req = URLRequest(url: Self.secureTwin(of: url), timeoutInterval: 8)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = NSImage(data: data),
              img.size.width > 1
        else { return nil }
        return img
    }

    /// Records a metadata entry, dropping the oldest once there are more than the disk keeps.
    private func remember(_ meta: CachedLinkMeta) {
        if metaCache[meta.url] == nil { metaOrder.append(meta.url) }
        metaCache[meta.url] = meta
        while metaOrder.count > maxDiskEntries {
            let oldest = metaOrder.removeFirst()
            metaCache.removeValue(forKey: oldest)
        }
    }

    private func cacheKey(for url: URL) -> String {
        let hash = url.absoluteString.utf8.reduce(UInt64(5381)) { ($0 &* 31) &+ UInt64($1) }
        return String(format: "%016llx", hash)
    }

    private func persistToDisk(_ meta: CachedLinkMeta) {
        guard let dir = cacheDir else { return }
        let file = dir.appendingPathComponent(cacheKey(for: meta.url) + ".json")
        try? JSONEncoder().encode(meta).write(to: file, options: .atomic)
    }

    private func loadDiskCache() {
        guard let dir = cacheDir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let meta = try? decoder.decode(CachedLinkMeta.self, from: data)
            else { continue }
            remember(meta)
        }
    }

    private func evictDiskIfNeeded() {
        guard let dir = cacheDir,
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
              ), files.count > maxDiskEntries else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        sorted.prefix(files.count - maxDiskEntries).forEach { try? FileManager.default.removeItem(at: $0) }
    }

    /// Every icon a page declares, largest first.
    ///
    /// It used to take whichever `<link rel=...icon>` appeared first in the markup, which is the
    /// small one: a page with an `apple-touch-icon` has 180 pixels there and 16 or 32 under
    /// `rel="icon"`, and the small one is usually written first. Ordering by declared size fixes
    /// that without ever leaving the page's own answer.
    ///
    /// `mask-icon` is dropped. It is Safari's pinned-tab glyph: a flat monochrome silhouette meant
    /// to be tinted by the browser, which on a card is a black blob.
    static func faviconURLs(in html: String, relativeTo base: URL) -> [URL] {
        iconLinks(in: html).compactMap { resolvedURL($0.href, relativeTo: base) }
    }

    /// The `<link>` tags that declare an icon, ordered largest first.
    ///
    /// Each whole tag is matched and then read attribute by attribute, rather than by one pattern
    /// trying to cover both attribute orders at once: `rel`, `href` and `sizes` appear in any order
    /// and a page may declare a dozen icons, and only reading them all can say which is biggest.
    static func iconLinks(in html: String) -> [(href: String, size: Int)] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\\\b[^>]*>", options: .caseInsensitive)
        else { return [] }
        var found: [(href: String, size: Int)] = []
        let whole = NSRange(html.startIndex..., in: html)
        for match in tags.matches(in: html, range: whole) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.contains("icon"), !rel.contains("mask-icon"),
                  let href = attribute("href", in: tag)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !href.isEmpty
            else { continue }
            found.append((href, declaredSize(of: tag, rel: rel)))
        }
        // Stable: two icons declared at the same size keep the order the page wrote them in.
        return found.enumerated()
            .sorted { $0.element.size != $1.element.size ? $0.element.size > $1.element.size
                                                        : $0.offset < $1.offset }
            .map(\.element)
    }

    /// How many pixels a declared icon claims. `sizes="32x32"` when it says so; 180 for an
    /// `apple-touch-icon`, which is that size by convention and the reason to prefer it.
    private static func declaredSize(of tag: String, rel: String) -> Int {
        if let sizes = attribute("sizes", in: tag)?.lowercased(),
           let first = sizes.split(separator: " ").first,
           let width = Int(first.split(separator: "x").first ?? "") {
            return width
        }
        return rel.contains("apple-touch-icon") ? 180 : 0
    }

    /// One attribute out of one tag, quoted either way.
    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\\\b\(NSRegularExpression.escapedPattern(for: name))\\\\s*=\\\\s*[\"']([^\"']*)[\"']"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: tag)
        else { return nil }
        return String(tag[r])
    }

    private func ogMeta(_ property: String, in html: String) -> String? {
        let esc = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "(?:property|name)=[\"']\(esc)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']\(esc)[\"']"
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: .caseInsensitive),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: html)
            else { continue }
            return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func pageTitle(in html: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<title[^>]*>([^<]+)</title>", options: .caseInsensitive),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: html)
        else { return nil }
        return String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
