import Foundation
import AppKit

struct LinkPreviewData {
    let title: String?
    let imageURL: URL?
    let image: NSImage?
    let domain: String?
}

private struct CachedLinkMeta: Codable {
    let url: URL
    let title: String?
    let imageURL: URL?
    let domain: String?
    var faviconURL: URL?
}

actor LinkPreviewService {
    static let shared = LinkPreviewService()

    private var metaCache: [URL: CachedLinkMeta] = [:]
    // NSCache (thread-safe, count-bounded) instead of plain dictionaries: the old dict eviction
    // removed `keys.first`, whose order is unspecified, so it could drop the entry just inserted,
    // and neither dict was ever bounded — decoded NSImages leaked for the whole session.
    private let imageCache = NSCache<NSURL, NSImage>()
    private let faviconCache = NSCache<NSString, NSImage>()
    private let maxDiskEntries = 200

    private let cacheDir: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("xPaste/LinkPreviews", isDirectory: true)

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

    init() {
        imageCache.countLimit = 50
        faviconCache.countLimit = 100
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

    func fetchMetadata(_ url: URL) async -> LinkPreviewData? {
        if let cached = metaCache[url] {
            return LinkPreviewData(title: cached.title, imageURL: cached.imageURL, image: nil, domain: cached.domain)
        }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }

        let title = ogMeta("og:title", in: html) ?? ogMeta("twitter:title", in: html) ?? pageTitle(in: html)
        let imgStr = ogMeta("og:image", in: html) ?? ogMeta("twitter:image", in: html)
        let domain = url.host?.replacingOccurrences(of: "www.", with: "")
        var ogImageURL: URL?
        if let s = imgStr { ogImageURL = Self.resolvedURL(s, relativeTo: url) }
        let favURL = htmlFaviconURL(in: html, relativeTo: url)

        var meta = CachedLinkMeta(url: url, title: title, imageURL: ogImageURL, domain: domain)
        meta.faviconURL = favURL
        // Don't cache a fully-empty result — an error/redirect page that still returns HTML
        // would otherwise poison the cache and block a real preview once the site recovers.
        if title != nil || ogImageURL != nil {
            metaCache[url] = meta
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
              let image = NSImage(data: imgData) else { return nil }

        imageCache.setObject(image, forKey: url as NSURL)
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
            faviconCache.setObject(img, forKey: host as NSString)
            return img
        }
        return nil
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
            metaCache[meta.url] = meta
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
