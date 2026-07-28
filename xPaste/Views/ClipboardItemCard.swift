import SwiftUI
import AppKit

struct ClipboardItemCard: View {
    let item: ClipboardItem
    let index: Int
    let isCopied: Bool

    @State private var isHovered = false
    @State private var loadedImage: NSImage?
    @State private var linkPreview: LinkPreviewData?
    @State private var linkImageChecked = false
    @State private var favicon: NSImage?
    @State private var pathImage: NSImage?
    @State private var computedAccentColor: Color?
    @State private var detectedFilePath: URL?
    @State private var detectedIsDirectory = false
    @AppStorage("linkPreviewEnabled") private var linkPreviewEnabled: Bool = true
    @Environment(\.panelScale) private var panelScale

    private static var colorCache: [String: Color] = [:]
    private static var iconCache: [String: NSImage] = [:]
    private static var unresolvedBundleIDs: Set<String> = []

    // Count-bounded NSCaches, not plain dicts: keyed by item UUID and written from .task,
    // the old dictionaries were never evicted, so every previewed image (thumbnails up to
    // 1000px + full clipboard images) stayed resident for the whole session even after the
    // item was deleted or history cleared.
    private static let pathImageCache: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>(); c.countLimit = 120; return c
    }()
    private static let loadedImageCache: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>(); c.countLimit = 120; return c
    }()
    private static var fileIconCache: [String: NSImage] = [:]

    /// Per-item strings that are expensive to derive but never change once captured.
    ///
    /// `footerLabel` used `String.count`, which walks the whole string: 0.015ms for a 1k-char
    /// item but 2.9ms for a 500k one — paid on every body pass, for every visible card. The
    /// preview likewise handed the entire string to `Text` and only then applied `lineLimit`,
    /// leaving TextKit to measure hundreds of kilobytes to draw seven lines.
    final class CardText {
        let footer: String
        let preview: String
        init(footer: String, preview: String) { self.footer = footer; self.preview = preview }
    }
    private static let cardTextCache: NSCache<NSUUID, CardText> = {
        let c = NSCache<NSUUID, CardText>(); c.countLimit = 300; return c
    }()
    /// Enough to fill the seven visible lines several times over.
    private static let previewCharLimit = 2000

    private func fileIcon(_ path: String) -> NSImage {
        if let cached = Self.fileIconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        Self.fileIconCache[path] = icon
        return icon
    }

    var body: some View {
        let accent = appAccentColor
        VStack(spacing: 0) {
            cardHeader(accent)
            contentPreview
            footer
        }
        .frame(width: PanelLayout.cardBaseWidth, height: PanelLayout.cardBaseHeight)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(CardSelectionBorder(itemID: item.id, isHovered: isHovered))
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
        .onHover { isHovered = $0 }
        .task(id: item.id) {
            if item.type == .image {
                if let data = item.imageData, let img = NSImage(data: data) {
                    loadedImage = img
                    Self.loadedImageCache.setObject(img, forKey: item.id as NSUUID)
                } else if item.imageData == nil {
                    loadedImage = await ClipboardStore.shared.loadImage(for: item.id)
                    if let loadedImage { Self.loadedImageCache.setObject(loadedImage, forKey: item.id as NSUUID) }
                }
            }

            // Resolve the path-detection (which touches the filesystem) ONCE here and cache it in
            // @State, instead of hitting FileManager on every `body` pass from cardHeader/footer.
            let resolved = resolveDetectedFilePath()
            if detectedFilePath != resolved.url { detectedFilePath = resolved.url }
            if detectedIsDirectory != resolved.isDir { detectedIsDirectory = resolved.isDir }

            let imageURL: URL? = {
                if item.type == .file, let url = item.fileURLs?.first, isImagePath(url) {
                    return url
                }
                if let pathURL = resolved.url, isImagePath(pathURL) {
                    return pathURL
                }
                return nil
            }()
            if let imageURL {
                let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    let opts: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1000,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                    ]
                    guard let src = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                }.value
                if let cgImage {
                    let image = NSImage(cgImage: cgImage, size: .zero)
                    pathImage = image
                    Self.pathImageCache.setObject(image, forKey: item.id as NSUUID)
                }
            }

            // Only publish a colour that had to be computed. `appAccentColor` already falls back
            // to `colorCache`, so assigning the cached value into @State changed nothing on
            // screen while forcing an extra body pass for every card scrolled into view.
            if let bundleID = item.sourceAppBundleID, Self.colorCache[bundleID] == nil {
                if let icon = sourceAppIcon,
                          let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let color = await Task.detached(priority: .utility) {
                        Self.extractDominantColor(from: cgImage)
                    }.value
                    if let color {
                        Self.colorCache[bundleID] = color
                        computedAccentColor = color
                    }
                }
            }

            guard item.type == .url, linkPreviewEnabled,
                  let urlStr = item.text, let url = URL(string: urlStr)
            else { return }

            if let meta = await LinkPreviewService.shared.fetchMetadata(url) {
                linkPreview = meta
            }

            if let img = await LinkPreviewService.shared.fetchImage(for: url) {
                linkPreview = LinkPreviewData(
                    title: linkPreview?.title,
                    imageURL: linkPreview?.imageURL,
                    image: img,
                    domain: linkPreview?.domain
                )
            }
            linkImageChecked = true

            if linkPreview?.image == nil {
                favicon = await LinkPreviewService.shared.fetchFavicon(for: url)
            }
        }
        // Shrink the whole card uniformly on shorter screens so it stays proportional to the
        // adaptively-sized panel. The trailing frame reserves the scaled footprint so layout,
        // hit-testing and the overlays added in ContentView all line up with what's drawn.
        .scaleEffect(panelScale, anchor: .center)
        .frame(width: PanelLayout.cardBaseWidth * panelScale,
               height: PanelLayout.cardBaseHeight * panelScale)
    }

    private func cardHeader(_ accent: Color) -> some View {
        let title: String = {
            if detectedColor != nil { return "Color" }
            if item.type == .file {
                let n = item.fileURLs?.count ?? 0
                return "\(n) file\(n == 1 ? "" : "s")"
            }
            if item.type == .folder {
                let n = item.fileURLs?.count ?? 0
                return "\(n) folder\(n == 1 ? "" : "s")"
            }
            if detectedFilePath != nil {
                return detectedIsDirectory ? "Folder" : "File"
            }
            return item.type.cardTitle
        }()
        // Headers now carry the app's real brightness, so a pale icon (Finder, Notes) yields a
        // pale bar that white text would vanish on. Flip the title to dark for those.
        let onAccent: Color = isPaleColor(accent) ? .black.opacity(0.78) : .white
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(onAccent)
                    .lineLimit(1)
                Text(item.timestamp.relativeString)
                    .font(.system(size: 10))
                    .foregroundColor(onAccent.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            Spacer()
            headerIcon
        }
        .frame(height: PanelLayout.cardHeaderHeight)
        .background(accent)
    }

    private var headerIcon: some View {
        Image(nsImage: sourceAppIcon ?? Self.fallbackAppIcon)
            .resizable()
            .scaledToFit()
            .frame(width: 77, height: 77)
            .offset(x: 14)
            .help(sourceAppName)
    }

    private static let fallbackAppIcon: NSImage =
        NSApp.applicationIconImage
        ?? NSImage(named: NSImage.applicationIconName)
        ?? NSImage()

    private static var nameCache: [String: String] = [:]
    private var sourceAppName: String {
        guard let bundleID = item.sourceAppBundleID else { return "xPaste" }
        if let cached = Self.nameCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "xPaste" }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        Self.nameCache[bundleID] = name
        return name
    }

    private var sourceAppIcon: NSImage? {
        guard let bundleID = item.sourceAppBundleID else { return nil }
        if let cached = Self.iconCache[bundleID] { return cached }
        // Remember failures too. Without this, an item captured from an app that has since been
        // uninstalled re-queries LaunchServices on every single body pass, forever.
        if Self.unresolvedBundleIDs.contains(bundleID) { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.unresolvedBundleIDs.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as! NSImage
        icon.size = NSSize(width: 64, height: 64)
        Self.iconCache[bundleID] = icon
        return icon
    }

    @ViewBuilder
    private var contentPreview: some View {
        ZStack(alignment: .topLeading) {
            Color(NSColor.textBackgroundColor)
            switch item.type {
            case .url:
                if linkPreviewEnabled, let img = linkPreview?.image {
                    Image(nsImage: img)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if linkPreviewEnabled, linkPreview != nil, linkImageChecked {
                    noImagePlaceholder
                } else {
                    textPreview
                }
            case .text:
                if let pathURL = detectedFilePath {
                    if let img = pathImage ?? Self.pathImageCache.object(forKey: item.id as NSUUID) {
                        Image(nsImage: img)
                            .resizable()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(nsImage: fileIcon(pathURL.path))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if let color = detectedColor {
                    colorPreview(color)
                } else {
                    textPreview
                }
            case .image:
                if let nsImage = loadedImage ?? Self.loadedImageCache.object(forKey: item.id as NSUUID) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder("photo", color: .purple)
                }
            case .file, .folder:
                if let img = pathImage ?? Self.pathImageCache.object(forKey: item.id as NSUUID) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let url = item.fileURLs?.first {
                    Image(nsImage: fileIcon(url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if item.type == .folder {
                    placeholder("folder.fill", color: .blue)
                } else {
                    placeholder("doc.fill", color: .orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(6)
            }
        }
    }

    private var textPreview: some View {
        Text(cardText.preview)
            .font(.system(size: 13))
            .foregroundColor(Color(NSColor.labelColor))
            .lineLimit(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
    }

    private func colorPreview(_ color: Color) -> some View {
        ZStack {
            color
            Text(item.text ?? "")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(isLightColor(color) ? Color.black.opacity(0.65) : Color.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 28))
            .foregroundColor(color.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noImagePlaceholder: some View {
        ZStack {
            // Paste puts the tint on the preview and leaves the footer plain; this used to be
            // the other way round, which read as an inverted card next to it.
            mutedBackground
            if let fav = favicon {
                Image(nsImage: fav)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)
            } else {
                Image("no_image")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 90)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        let hasLinkPreview = item.type == .url && linkPreviewEnabled && linkPreview != nil
        if hasLinkPreview {
            urlPreviewFooter
        } else if item.type == .file || item.type == .folder || detectedFilePath != nil {
            fileFooter
        } else {
            defaultFooter
        }
    }

    /// A subtly tinted fill, used for the parts of a card that sit behind its content.
    private var mutedBackground: some View {
        ZStack {
            Color(NSColor.textBackgroundColor)
            Color.primary.opacity(0.08)
        }
    }

    private var shortcutBadge: some View {
        ShortcutBadge(index: index)
    }

    private var urlPreviewFooter: some View {
        HStack(alignment: .bottom, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(linkPreview?.title ?? item.text ?? "")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .foregroundColor(Color(NSColor.labelColor))
                Text(item.text ?? "")
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
            }
            // Claim the leftover width explicitly so the title/URL truncate around the badge.
            .frame(maxWidth: .infinity, alignment: .leading)
            shortcutBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(Color(NSColor.textBackgroundColor))
    }

    private var fileFooter: some View {
        let path = item.fileURLs?.first?.path ?? item.text ?? ""
        return HStack(spacing: 0) {
            Text(path)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            shortcutBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(height: 30)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var defaultFooter: some View {
        Text(footerLabel)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(height: 30)
            // Overlaid rather than placed in an HStack: this label is short and centred, so it
            // can never collide with the badge, and laying the badge out inline would re-centre
            // the label in the leftover width — nudging "N characters" left on every ⌘ press.
            .overlay(alignment: .trailing) {
                shortcutBadge.padding(.trailing, 12)
            }
            .background(Color(NSColor.controlBackgroundColor))
    }

    private var footerLabel: String { cardText.footer }

    private var cardText: CardText {
        if let cached = Self.cardTextCache.object(forKey: item.id as NSUUID) { return cached }
        let built = CardText(footer: buildFooterLabel(),
                             preview: String((item.text ?? "").prefix(Self.previewCharLimit)))
        Self.cardTextCache.setObject(built, forKey: item.id as NSUUID)
        return built
    }

    private func buildFooterLabel() -> String {
        switch item.type {
        case .text, .url:
            let n = item.text?.count ?? 0
            return "\(n) characters"
        case .image:
            let kb = (item.imageSize ?? item.imageData?.count ?? 0) / 1024
            return "\(kb) KB"
        case .file:
            let n = item.fileURLs?.count ?? 0
            return "\(n) file\(n == 1 ? "" : "s")"
        case .folder:
            let n = item.fileURLs?.count ?? 0
            return "\(n) folder\(n == 1 ? "" : "s")"
        }
    }

    private var appAccentColor: Color {
        guard let bundleID = item.sourceAppBundleID else { return item.type.accentColor }
        return computedAccentColor ?? Self.colorCache[bundleID] ?? item.type.accentColor
    }

    /// Brand colour of an app, taken from its icon.
    ///
    /// Picking the single most saturated pixel does not work: it ignores how much of the
    /// icon a colour actually covers, so Chrome resolved to the green arc of its ring
    /// (the smallest, most saturated patch) instead of the blue disc everyone reads as
    /// "Chrome". Icons put their mark in the middle and their filler at the rim, so hues
    /// are binned into a histogram weighted by distance from the centre — Chrome's blue is
    /// 9.5% of the icon by raw area but 61% of its central third.
    private nonisolated static func extractDominantColor(from cgImage: CGImage) -> Color? {
        let size = 32
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        let bucketCount = 24
        var bucketWeight = [CGFloat](repeating: 0, count: bucketCount)
        var bucketR = [CGFloat](repeating: 0, count: bucketCount)
        var bucketG = [CGFloat](repeating: 0, count: bucketCount)
        var bucketB = [CGFloat](repeating: 0, count: bucketCount)
        // Greys are tracked separately: an icon that is entirely black/white (Terminal) has
        // no hue to win, and must not be forced into whichever hue the anti-aliasing leaked.
        var greyWeight: CGFloat = 0, greyR: CGFloat = 0, greyG: CGFloat = 0, greyB: CGFloat = 0

        let sigma: CGFloat = 0.35
        for y in 0..<size {
            for x in 0..<size {
                let o = (y * size + x) * 4
                let a = CGFloat(px[o + 3]) / 255
                guard a > 0.5 else { continue }
                let r = CGFloat(px[o]) / 255
                let g = CGFloat(px[o + 1]) / 255
                let b = CGFloat(px[o + 2]) / 255
                guard let ns = NSColor(red: r, green: g, blue: b, alpha: 1)
                        .usingColorSpace(.deviceRGB) else { continue }
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
                ns.getHue(&h, saturation: &s, brightness: &v, alpha: nil)

                let dx = (CGFloat(x) + 0.5) / CGFloat(size) - 0.5
                let dy = (CGFloat(y) + 0.5) / CGFloat(size) - 0.5
                let dist = (dx * dx + dy * dy).squareRoot() / 0.5
                let centre = exp(-(dist * dist) / (2 * sigma * sigma))

                if s < 0.18 {
                    greyWeight += centre; greyR += r * centre; greyG += g * centre; greyB += b * centre
                    continue
                }
                // Weight by saturation as well, so a pale wash behind the mark cannot outvote it.
                let w = centre * s
                let i = min(bucketCount - 1, Int(h * CGFloat(bucketCount)))
                bucketWeight[i] += w; bucketR[i] += r * w; bucketG[i] += g * w; bucketB[i] += b * w
            }
        }

        var best = -1
        var bestWeight: CGFloat = 0
        for i in 0..<bucketCount where bucketWeight[i] > bestWeight {
            bestWeight = bucketWeight[i]; best = i
        }

        let raw: NSColor
        if best >= 0, bestWeight > greyWeight * 0.25 {
            raw = NSColor(red: bucketR[best] / bestWeight,
                          green: bucketG[best] / bestWeight,
                          blue: bucketB[best] / bestWeight, alpha: 1)
        } else if greyWeight > 0 {
            raw = NSColor(red: greyR / greyWeight, green: greyG / greyWeight,
                          blue: greyB / greyWeight, alpha: 1)
        } else {
            return nil
        }

        guard let ns = raw.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        // Keep the app's own saturation and brightness rather than flattening every header to
        // one dark tone; only clamp far enough to keep the header title legible on top of it.
        return Color(hue: h,
                     saturation: min(s, 0.85),
                     brightness: min(max(v, 0.32), 0.92))
    }

    private var detectedColor: Color? {
        guard item.type == .text, let text = item.text else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return parseHexColor(t) ?? parseRGBColor(t) ?? parseHSLColor(t)
    }

    private func isImagePath(_ url: URL) -> Bool {
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif"]
        return imageExts.contains(url.pathExtension.lowercased())
    }

    /// Resolve whether this text item is an existing file/folder path. Hits the filesystem, so
    /// it's called once from `.task` and the result is cached in @State — never from `body`.
    private func resolveDetectedFilePath() -> (url: URL?, isDir: Bool) {
        guard item.type == .text,
              let raw = item.text
        else { return (nil, false) }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"),
              text.hasPrefix("/") || text.hasPrefix("~/")
        else { return (nil, false) }
        let expanded = (text as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else { return (nil, false) }
        return (URL(fileURLWithPath: expanded), isDir.boolValue)
    }

    private func parseHexColor(_ s: String) -> Color? {
        guard s.hasPrefix("#") else { return nil }
        var hex = String(s.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 6, let val = UInt32(hex, radix: 16) {
            return Color(red: Double((val >> 16) & 0xFF) / 255,
                         green: Double((val >> 8) & 0xFF) / 255,
                         blue: Double(val & 0xFF) / 255)
        }
        if hex.count == 8, let val = UInt32(hex, radix: 16) {
            return Color(red: Double((val >> 24) & 0xFF) / 255,
                         green: Double((val >> 16) & 0xFF) / 255,
                         blue: Double((val >> 8) & 0xFF) / 255,
                         opacity: Double(val & 0xFF) / 255)
        }
        return nil
    }

    private static let rgbRegex = try? NSRegularExpression(
        pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([\d.]+))?\s*\)$"#,
        options: .caseInsensitive)
    private static let hslRegex = try? NSRegularExpression(
        pattern: #"^hsla?\(\s*([\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%(?:\s*,\s*([\d.]+))?\s*\)$"#,
        options: .caseInsensitive)

    private func parseRGBColor(_ s: String) -> Color? {
        guard s.count >= 10, s.lowercased().hasPrefix("rgb"),
              let regex = Self.rgbRegex,
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func cap(_ i: Int) -> Double? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return Double(s[r])
        }
        guard let r = cap(1), let g = cap(2), let b = cap(3),
              r <= 255, g <= 255, b <= 255 else { return nil }
        return Color(red: r / 255, green: g / 255, blue: b / 255, opacity: cap(4) ?? 1.0)
    }

    private func parseHSLColor(_ s: String) -> Color? {
        guard s.count >= 10, s.lowercased().hasPrefix("hsl"),
              let regex = Self.hslRegex,
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func cap(_ i: Int) -> Double? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return Double(s[r])
        }
        guard let h = cap(1), let s = cap(2), let l = cap(3) else { return nil }
        return hslToColor(h: h / 360, s: s / 100, l: l / 100, a: cap(4) ?? 1.0)
    }

    private func hslToColor(h: Double, s: Double, l: Double, a: Double) -> Color {
        if s == 0 { return Color(red: l, green: l, blue: l, opacity: a) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue2rgb(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        return Color(red: hue2rgb(h + 1/3), green: hue2rgb(h), blue: hue2rgb(h - 1/3), opacity: a)
    }

    /// Whether a header bar is pale enough to need dark text. Deliberately higher than the 0.5
    /// mid-point `isLightColor` uses: white still reads better on saturated brand colours such
    /// as Mail's or Xcode's blue, whose luminance drifts just past 0.5 on the green coefficient.
    private func isPaleColor(_ color: Color) -> Bool {
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return true }
        let luminance = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return luminance > 0.62
    }

    private func isLightColor(_ color: Color) -> Bool {
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return true }
        let luminance = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return luminance > 0.5
    }
}

private extension ClipboardContentType {
    var cardTitle: String {
        switch self {
        case .text:   return "Text"
        case .url:    return "Link"
        case .image:  return "Image"
        case .file:   return "File"
        case .folder: return "Folder"
        }
    }

    var iconName: String {
        switch self {
        case .text:   return "text.alignleft"
        case .url:    return "link"
        case .image:  return "photo"
        case .file:   return "doc.fill"
        case .folder: return "folder.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .text:   return .blue
        case .url:    return Color(red: 0.1, green: 0.6, blue: 0.3)
        case .image:  return .purple
        case .file:   return .orange
        case .folder: return .blue
        }
    }
}

/// The ⌘-number hint in a card's footer.
///
/// A view of its own, observing `ModifierWatcher` directly, so a modifier press rebuilds only
/// these few labels. Reading the flags through the environment from `ContentView` instead cost
/// a full-panel re-layout on every press (~40ms measured, Release and Debug alike).
private struct ShortcutBadge: View {
    let index: Int
    @ObservedObject private var watcher = ModifierWatcher.shared

    var body: some View {
        if watcher.flags.contains(.command), index <= 9 {
            HStack(spacing: 4) {
                if watcher.flags.contains(.shift) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 10))
                }
                Text("\(index)")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
            .fixedSize()
            .padding(.leading, 6)
        }
    }
}

/// The hover/selection ring around a card.
///
/// Split out so that it, rather than the whole card, is what observes `PanelSelection`. Moving
/// the selection then rebuilds a handful of stroked rectangles instead of every visible card
/// body — and nothing at all in ContentView.
///
/// Drawn in the system accent colour rather than the source app's, which is what Paste does too:
/// its cards carry an orange header and a blue ring. Tying the ring to the app colour made it
/// invisible whenever that colour was pale — a card copied from TextEdit drew a near-white ring
/// on the panel's near-white glass. The app's colour still identifies the card, in the header.
private struct CardSelectionBorder: View {
    let itemID: UUID
    let isHovered: Bool
    @ObservedObject private var selection = PanelSelection.shared

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke((isHovered || selection.contains(itemID)) ? Color.accentColor : .clear,
                    lineWidth: 3)
    }
}
