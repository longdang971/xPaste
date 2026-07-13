import SwiftUI
import AppKit

struct ClipboardItemCard: View {
    let item: ClipboardItem
    let index: Int
    let isCopied: Bool
    var isSelected: Bool = false

    @State private var isHovered = false
    @State private var loadedImage: NSImage?
    @State private var linkPreview: LinkPreviewData?
    @State private var linkImageChecked = false
    @State private var favicon: NSImage?
    @State private var pathImage: NSImage?
    @State private var computedAccentColor: Color?
    @AppStorage("linkPreviewEnabled") private var linkPreviewEnabled: Bool = true
    @Environment(\.panelScale) private var panelScale

    private static var colorCache: [String: Color] = [:]
    private static var iconCache: [String: NSImage] = [:]

    private static var pathImageCache: [UUID: NSImage] = [:]
    private static var loadedImageCache: [UUID: NSImage] = [:]
    private static var fileIconCache: [String: NSImage] = [:]

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
        .frame(width: 250, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    (isHovered || isSelected) ? accent : .clear,
                    lineWidth: 2
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
        .onHover { isHovered = $0 }
        .task(id: item.id) {
            if item.type == .image {
                if let data = item.imageData, let img = NSImage(data: data) {
                    loadedImage = img
                    Self.loadedImageCache[item.id] = img
                } else if item.imageData == nil {
                    loadedImage = await ClipboardStore.shared.loadImage(for: item.id)
                    if let loadedImage { Self.loadedImageCache[item.id] = loadedImage }
                }
            }

            let imageURL: URL? = {
                if item.type == .file, let url = item.fileURLs?.first, isImagePath(url) {
                    return url
                }
                if let pathURL = detectedFilePath, isImagePath(pathURL) {
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
                    Self.pathImageCache[item.id] = image
                }
            }

            if let bundleID = item.sourceAppBundleID {
                if let cached = Self.colorCache[bundleID] {
                    computedAccentColor = cached
                } else if let icon = sourceAppIcon,
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
        .frame(width: 250 * panelScale, height: 240 * panelScale)
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
            if let pathURL = detectedFilePath {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: pathURL.path, isDirectory: &isDir)
                return isDir.boolValue ? "Folder" : "File"
            }
            return item.type.cardTitle
        }()
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(item.timestamp.relativeString)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(.leading, 12)
            Spacer()
            headerIcon
        }
        .frame(height: 58)
        .background(accent)
    }

    private var headerIcon: some View {
        Image(nsImage: sourceAppIcon ?? Self.fallbackAppIcon)
            .resizable()
            .scaledToFit()
            .frame(width: 84, height: 84)
            .offset(x: 13)
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
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
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
                    if let img = pathImage ?? Self.pathImageCache[item.id] {
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
                if let nsImage = loadedImage ?? Self.loadedImageCache[item.id] {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder("photo", color: .purple)
                }
            case .file, .folder:
                if let img = pathImage ?? Self.pathImageCache[item.id] {
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
        Text(item.text ?? "")
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
            Color(NSColor.textBackgroundColor)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 52)
        .background(
            ZStack {
                Color(NSColor.textBackgroundColor)
                Color.primary.opacity(0.08)
            }
        )
    }

    private var fileFooter: some View {
        let path = item.fileURLs?.first?.path ?? item.text ?? ""
        return Text(path)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(.vertical, 7)
            .frame(height: 30)
            .background(Color(NSColor.controlBackgroundColor))
    }

    private var footerLabel: String {
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

    private nonisolated static func extractDominantColor(from cgImage: CGImage) -> Color? {
        let size = 16
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        var bestSat: CGFloat = 0.2
        var bestHue: CGFloat = 0
        var foundSaturated = false
        var totalR: CGFloat = 0, totalG: CGFloat = 0, totalB: CGFloat = 0
        var count: CGFloat = 0

        for i in 0..<(size * size) {
            let o = i * 4
            let r = CGFloat(px[o]) / 255
            let g = CGFloat(px[o + 1]) / 255
            let b = CGFloat(px[o + 2]) / 255
            let a = CGFloat(px[o + 3]) / 255
            guard a > 0.5 else { continue }

            totalR += r; totalG += g; totalB += b; count += 1

            guard let ns = NSColor(red: r, green: g, blue: b, alpha: 1).usingColorSpace(.deviceRGB) else { continue }
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
            guard v > 0.15 && v < 0.98 else { continue }
            if s > bestSat { bestSat = s; bestHue = h; foundSaturated = true }
        }

        if foundSaturated {
            return Color(hue: bestHue, saturation: 0.65, brightness: 0.52)
        }
        guard count > 0 else { return nil }
        return Color(red: totalR / count, green: totalG / count, blue: totalB / count)
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

    private var detectedFilePath: URL? {
        guard item.type == .text,
              let raw = item.text
        else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"),
              text.hasPrefix("/") || text.hasPrefix("~/")
        else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded)
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
