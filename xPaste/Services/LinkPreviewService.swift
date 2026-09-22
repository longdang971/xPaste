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
}

private struct CachedLinkMeta: Codable {
    let url: URL
    let title: String?
    let imageURL: URL?
    let domain: String?
    var faviconURL: URL?
    // Optional rather than defaulted: synthesised `Codable` has no notion of a property default,
    // so a non-optional here would fail to decode every entry already on disk.
    var isDirectImage: Bool?
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
        for needle in [Data("</head>".utf8), Data("</HEAD>".utf8)] {
            if let found = ceiling.range(of: needle) { return ceiling.prefix(upTo: found.upperBound) }
        }
        return ceiling
    }
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

    func fetchMetadata(_ url: URL) async -> LinkPreviewData? {
        if let cached = metaCache[url] {
            return LinkPreviewData(title: cached.title, imageURL: cached.imageURL, image: nil,
                                   domain: cached.domain,
                                   isDirectImage: cached.isDirectImage ?? false)
        }

        // The request goes to the https twin; everything below still files the result under the
        // URL the caller asked about, which is the one the item holds. See `secureTwin`.
        let target = Self.secureTwin(of: url)
        var req = URLRequest(url: target, timeoutInterval: 8)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        let domain = url.host?.replacingOccurrences(of: "www.", with: "")

        // A URL that names a picture is its own preview: the image URL is the link itself, and the
        // bytes are already here, so seed the image cache rather than fetch the same file twice.
        // Decodable, not merely declared: an `image/svg+xml` that `NSImage` cannot open falls
        // through to the scrape below and keeps the favicon card it used to get.
        if Self.isDirectImage(mimeType: resp.mimeType),
           Self.withinCap(resp, data, cap: Self.imageByteCap),
           let image = NSImage(data: data) {
            imageCache.setObject(image, forKey: url as NSURL, cost: image.approximateDecodedBytes)
            var meta = CachedLinkMeta(url: url, title: nil, imageURL: target, domain: domain)
            meta.isDirectImage = true
            remember(meta)
            persistToDisk(meta)
            evictDiskIfNeeded()
            return LinkPreviewData(title: nil, imageURL: target, image: nil, domain: domain,
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
        let favURL = htmlFaviconURL(in: html, relativeTo: target)

        var meta = CachedLinkMeta(url: url, title: title, imageURL: ogImageURL, domain: domain)
        meta.faviconURL = favURL
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

        var candidates: [URL] = []
        if let favURL = metaCache[url]?.faviconURL {
            candidates.append(favURL)
        }
        candidates += Self.faviconServices(for: host)

        var best: NSImage?
        var bestPixels = 0
        for favURL in candidates {
            var req = URLRequest(url: Self.secureTwin(of: favURL), timeoutInterval: 8)
            req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data),
                  img.size.width > 1
            else { continue }
            let pixels = img.representations.map(\.pixelsWide).max() ?? 0
            if pixels > bestPixels { best = img; bestPixels = pixels }
            if bestPixels >= Self.faviconMinPixels { break }
        }
        if let best {
            faviconCache.setObject(best, forKey: host as NSString, cost: best.approximateDecodedBytes)
        }
        return best
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

    /// The icon a page declares for itself.
    ///
    /// `apple-touch-icon` is asked for first and separately. A page that has one has a 180-pixel
    /// icon there and a 16- or 32-pixel one under `rel="icon"`, and taking whichever appeared first
    /// in the markup is how a card ended up stretching 32 pixels across the plate.
    private func htmlFaviconURL(in html: String, relativeTo base: URL) -> URL? {
        for rel in ["apple-touch-icon", "shortcut icon|icon"] {
            if let found = faviconHref(matching: rel, in: html, relativeTo: base) { return found }
        }
        return nil
    }

    private func faviconHref(matching rel: String, in html: String, relativeTo base: URL) -> URL? {
        let pattern = #"<link[^>]+rel=["'](?:\#(rel))["'][^>]+href=["']([^"']+)["']"#
                    + #"|<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:\#(rel))["']"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        else { return nil }
        for g in 1...2 {
            guard m.range(at: g).location != NSNotFound,
                  let r = Range(m.range(at: g), in: html) else { continue }
            let href = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = Self.resolvedURL(href, relativeTo: base) { return resolved }
        }
        return nil
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
