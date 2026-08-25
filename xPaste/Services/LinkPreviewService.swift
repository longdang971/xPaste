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

    /// A page is read for the handful of `<meta>` tags in its head. Anything past this is markup
    /// nobody here looks at, and decoding it into a `String` — which the ISO-Latin-1 fallback
    /// always succeeds at — would put the whole document in memory and then run six regexes over
    /// it. A ten-megabyte page cost ten megabytes of `String` for a title.
    private static let htmlScanCap = 512 * 1024
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

    func fetchMetadata(_ url: URL) async -> LinkPreviewData? {
        if let cached = metaCache[url] {
            return LinkPreviewData(title: cached.title, imageURL: cached.imageURL, image: nil,
                                   domain: cached.domain,
                                   isDirectImage: cached.isDirectImage ?? false)
        }

        var req = URLRequest(url: url, timeoutInterval: 8)
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
            var meta = CachedLinkMeta(url: url, title: nil, imageURL: url, domain: domain)
            meta.isDirectImage = true
            remember(meta)
            persistToDisk(meta)
            evictDiskIfNeeded()
            return LinkPreviewData(title: nil, imageURL: url, image: nil, domain: domain,
                                   isDirectImage: true)
        }

        // Only the head is of interest, and only a bounded amount of it. Truncated at a byte
        // count, so a UTF-8 sequence can be cut in half — the ISO-Latin-1 fallback below decodes
        // whatever UTF-8 rejects, and a mangled tail cannot affect tags that appear near the top.
        let scanned = data.prefix(Self.htmlScanCap)
        guard let html = String(data: scanned, encoding: .utf8)
                ?? String(data: scanned, encoding: .isoLatin1)
        else { return nil }

        let title = ogMeta("og:title", in: html) ?? ogMeta("twitter:title", in: html) ?? pageTitle(in: html)
        let imgStr = ogMeta("og:image", in: html) ?? ogMeta("twitter:image", in: html)
        var ogImageURL: URL?
        if let s = imgStr { ogImageURL = Self.resolvedURL(s, relativeTo: url) }
        let favURL = htmlFaviconURL(in: html, relativeTo: url)

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
        var req = URLRequest(url: imageURL, timeoutInterval: 8)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let (imgData, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              Self.withinCap(resp, imgData, cap: Self.imageByteCap),
              let image = NSImage(data: imgData) else { return nil }

        imageCache.setObject(image, forKey: url as NSURL, cost: image.approximateDecodedBytes)
        return image
    }

    func fetchFavicon(for url: URL) async -> NSImage? {
        guard let host = url.host else { return nil }
        if let cached = faviconCache.object(forKey: host as NSString) { return cached }

        var candidates: [String] = []
        if let favURL = metaCache[url]?.faviconURL?.absoluteString {
            candidates.append(favURL)
        }
        candidates += [
            "https://www.google.com/s2/favicons?domain=\(host)&sz=64",
            "https://icons.duckduckgo.com/ip3/\(host).ico",
        ]

        for urlStr in candidates {
            guard let favURL = URL(string: urlStr) else { continue }
            var req = URLRequest(url: favURL, timeoutInterval: 8)
            req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let img = NSImage(data: data),
                  img.size.width > 1
            else { continue }
            faviconCache.setObject(img, forKey: host as NSString, cost: img.approximateDecodedBytes)
            return img
        }
        return nil
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

    private func htmlFaviconURL(in html: String, relativeTo base: URL) -> URL? {
        let pattern = #"<link[^>]+rel=["'](?:shortcut icon|icon|apple-touch-icon)["'][^>]+href=["']([^"']+)["']|<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:shortcut icon|icon|apple-touch-icon)["']"#
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
