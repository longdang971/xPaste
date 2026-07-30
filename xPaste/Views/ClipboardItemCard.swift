import SwiftUI
import AppKit

/// The quick actions a card offers while the pointer is over it. Handed in from `ContentView`,
/// which owns the store and the share picker.
struct CardActions {
    let isPinned: Bool
    let togglePin: () -> Void
    let delete: () -> Void
}

/// What a card's `.task` is keyed on.
///
/// `.task(id:)` takes a single `Equatable`, and the card's work depends on two things: which item
/// it is showing, and which appearance it is showing it in. A light/dark flip must re-run the task
/// so the rich preview is rebuilt for the mode now on screen.
struct CardTaskKey: Equatable {
    let itemID: UUID
    let isLightAppearance: Bool
}

struct ClipboardItemCard: View {
    let item: ClipboardItem
    let index: Int
    let isCopied: Bool
    var actions: CardActions? = nil
    /// Turns the header title into an editable field. Driven by ContentView, which owns
    /// "which card is being renamed" so only one can be at a time.
    var isRenaming: Bool = false
    /// Called once when editing ends: the new name, or nil if the user cancelled.
    var onRenameEnd: ((String?) -> Void)? = nil

    @State private var isHovered = false
    @State private var draftName = ""
    @State private var renameEnded = false
    @FocusState private var nameFieldFocused: Bool
    @State private var loadedImage: NSImage?
    @State private var linkPreview: LinkPreviewData?
    @State private var linkImageChecked = false
    @State private var favicon: NSImage?
    @State private var pathImage: NSImage?
    @State private var richPreview: RichCardPreview?
    @State private var computedAccentColor: Color?
    @State private var detectedFilePath: URL?
    @State private var detectedIsDirectory = false
    @AppStorage("linkPreviewEnabled") private var linkPreviewEnabled: Bool = true
    @Environment(\.panelScale) private var panelScale
    /// A rich preview is a baked bitmap, so it belongs to one appearance. Reading the scheme here
    /// makes the card rebuild — rather than keep showing yesterday's white rectangle — when the
    /// system flips between light and dark.
    @Environment(\.colorScheme) private var colorScheme

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
    /// Rich previews, positive and negative alike: an item that resolved to plain text is stored
    /// as `RichCardPreview.plain` so it is never parsed twice.
    private static let richPreviewCache: NSCache<NSUUID, RichCardPreview> = {
        let c = NSCache<NSUUID, RichCardPreview>(); c.countLimit = 120; return c
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
        // Keyed on the appearance as well as the item: `.task(id:)` takes one Equatable value, so
        // the two are combined. A light/dark flip re-runs this and rebuilds the rich preview for
        // the appearance now on screen.
        .task(id: CardTaskKey(itemID: item.id, isLightAppearance: isLightAppearance)) {
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

            // Built here, never in `body`: parsing RTF and laying it out is TextKit work, and a
            // card that did it per body pass would re-measure on every panel re-layout.
            if item.richData != nil,
               item.type == .text || item.type == .url,
               resolved.url == nil,
               detectedColor == nil {
                let light = isLightAppearance
                if let cached = Self.richPreviewCache.object(forKey: item.id as NSUUID),
                   cached.isUsable(underLightAppearance: light) {
                    if richPreview !== cached { richPreview = cached }
                } else {
                    // The default fill is resolved for the appearance on screen, so both the
                    // bitmap's background and the legibility verdict belong to it.
                    let built = await RichTextRenderer.cardPreview(
                        for: item, size: RichTextRenderer.cardPreviewSize,
                        forLightAppearance: light,
                        defaultFill: RichTextRenderer.defaultFill(forLightAppearance: light))
                    Self.richPreviewCache.setObject(built, forKey: item.id as NSUUID)
                    richPreview = built
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

    /// What the header shows when the item has no name of its own.
    private var derivedTitle: String {
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
    }

    /// The header title: a name the user gave this item wins over every derived title — that
    /// name is the whole point of pinning something as a snippet.
    private var headerTitle: String {
        if let label = item.label, !label.isEmpty { return label }
        return derivedTitle
    }

    private func cardHeader(_ accent: Color) -> some View {
        // Headers now carry the app's real brightness, so a pale icon (Finder, Notes) yields a
        // pale bar that white text would vanish on. Flip the title to dark for those.
        let onAccent: Color = isPaleColor(accent) ? .black.opacity(0.78) : .white
        return HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    nameField(onAccent: onAccent)
                } else {
                    Text(headerTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(onAccent)
                        .lineLimit(1)
                }
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

    /// The header title, editable in place.
    ///
    /// Return commits, Escape cancels, and clicking away commits — the Finder rule. `renameEnded`
    /// makes sure only the first of those wins: ending the edit drops focus, which would
    /// otherwise fire the click-away commit right after a cancel and undo it.
    /// No box, no highlight: the title keeps its exact look and only gains a caret, so editing
    /// reads as typing over the title itself rather than as a field appearing on the card.
    private func nameField(onAccent: Color) -> some View {
        TextField("", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(onAccent)
            // The caret rides the title's colour, not the system accent: a blue accent on a blue
            // header (Chrome) leaves nothing to see.
            .tint(onAccent)
            .focused($nameFieldFocused)
            .lineLimit(1)
            .frame(width: PanelLayout.cardBaseWidth - 108, alignment: .leading)
            .onSubmit { finishRename(with: draftName) }
            .onExitCommand { finishRename(with: nil) }
            .onChange(of: nameFieldFocused) { focused in
                if !focused { finishRename(with: draftName) }
            }
            .onAppear {
                // Start from what the header already reads — including a derived title like
                // "Link" — so nothing vanishes when the edit begins and the user can just keep
                // typing onto it.
                draftName = headerTitle
                renameEnded = false
                // Same delay the search box uses: the field has to exist in the responder
                // chain before focus will stick.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    nameFieldFocused = true
                    placeCaretAtEnd()
                }
            }
    }

    /// SwiftUI hands a newly focused text field a select-all, so the first keystroke would wipe
    /// the name instead of extending it. Collapse that selection to the end via the field editor.
    private func placeCaretAtEnd() {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            let end = (editor.string as NSString).length
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    private func finishRename(with value: String?) {
        guard !renameEnded else { return }
        renameEnded = true
        onRenameEnd?(value)
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
            Color(nsColor: richFill ?? .textBackgroundColor)
            switch item.type {
            case .url:
                if linkPreviewEnabled, let img = linkPreview?.image {
                    Image(nsImage: img)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if linkPreviewEnabled, linkPreview != nil, linkImageChecked {
                    noImagePlaceholder
                } else {
                    richOrTextPreview
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
                    richOrTextPreview
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
            // The hover buttons take this corner while they're up: the pin button already shows
            // the pinned state, so keeping the static indicator too would just be two pins.
            if let actions, isHovered {
                CardHoverActions(actions: actions, fill: richFill)
                    .padding(6)
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.red)
                    .padding(6)
            }
        }
    }

    /// Whether the appearance the card is being drawn in is the light one.
    private var isLightAppearance: Bool { colorScheme == .light }

    /// The cached decision for this item. Reads the cache directly as well as `@State` so a card
    /// scrolled back into view draws its preview on the first body pass, not one pass later.
    ///
    /// An entry built under the other appearance is a miss, not a fallback: its bitmap was baked
    /// with the other mode's `textBackgroundColor`, and its rich-or-plain verdict was decided
    /// against that fill. Returning nil here draws the plain text for the one body pass it takes
    /// `.task` to rebuild, rather than leaving a white rectangle on a dark panel.
    private var resolvedRichPreview: RichCardPreview? {
        let entry = richPreview ?? Self.richPreviewCache.object(forKey: item.id as NSUUID)
        guard let entry, entry.isUsable(underLightAppearance: isLightAppearance) else { return nil }
        return entry
    }

    /// Whether this card is drawing its rich bitmap on this body pass.
    ///
    /// A `.url` card is excluded as soon as its link metadata arrives: from that moment the footer
    /// is the 52pt `urlPreviewFooter` rather than the 30pt default one, so the content rect is
    /// 132pt while the bitmap was laid out for 154pt, and `.clipped()` would cut off its bottom.
    /// That window lasts until the image fetch returns and one of the link branches takes over.
    /// The plain `textPreview` reflows into whatever rect it is given, so it is what draws there —
    /// the bitmap is never resized, since having exactly one bitmap size is the point of caching.
    ///
    /// The condition is exactly the one `footer` switches on, so the two can never disagree.
    private var drawsRichPreview: Bool {
        guard resolvedRichPreview?.image != nil else { return false }
        if item.type == .url, linkPreviewEnabled, linkPreview != nil { return false }
        return true
    }

    /// The fill this card's preview and footer share, or nil to keep the default colours.
    ///
    /// Tied to `drawsRichPreview`, not merely to the cached entry: a card falling back to plain
    /// text must not keep a black fill, or its `labelColor` text would sit on black.
    private var richFill: NSColor? { drawsRichPreview ? resolvedRichPreview?.fill : nil }

    /// The formatted preview when there is one, the plain text otherwise.
    @ViewBuilder
    private var richOrTextPreview: some View {
        if drawsRichPreview, let image = resolvedRichPreview?.image {
            // No `.resizable()`: the bitmap was laid out at exactly this size, and stretching it
            // would distort the glyphs. Top-leading + clipped truncates the way the layout does.
            Image(nsImage: image)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            textPreview
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
        let tint = Self.onSwatchTint(NSColor(color))
        return ZStack {
            color
            Text(item.text ?? "")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The badge lives here rather than in a footer, because a swatch card has no footer for it
        // to live in. Same seat it occupies on every other card: bottom-right, 12pt in.
        .overlay(alignment: .bottomTrailing) {
            ShortcutBadge(index: index, tint: tint)
                .padding(.trailing, 12)
                .padding(.bottom, 9)
        }
    }

    /// The tint for glyphs drawn straight onto a colour swatch — the hex label and the ⌘-number
    /// badge alike, so the two cannot disagree about whether the colour behind them is light and
    /// leave one of them sunk into it.
    static func onSwatchTint(_ swatch: NSColor) -> Color {
        isLight(swatch) ? Color.black.opacity(0.65) : Color.white.opacity(0.85)
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
        if detectedColor != nil {
            // No strip at all: a swatch runs to the bottom edge, and window chrome beneath it
            // reads as the colour stopping short of the card it is supposed to be. "7 characters"
            // says nothing about a colour anyway. `contentPreview` claims the height instead, so
            // the card's total is unchanged and the hex label centres on the whole block.
            EmptyView()
        } else if hasLinkPreview {
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
        .frame(height: PanelLayout.cardFooterHeight)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var defaultFooter: some View {
        Text(footerLabel)
            .font(.system(size: 11))
            .foregroundColor(Self.footerTextColor(on: richFill))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(height: PanelLayout.cardFooterHeight)
            // Overlaid rather than placed in an HStack: this label is short and centred, so it
            // can never collide with the badge, and laying the badge out inline would re-centre
            // the label in the leftover width — nudging "N characters" left on every ⌘ press.
            .overlay(alignment: .trailing) {
                shortcutBadge.padding(.trailing, 12)
            }
            // Paste runs the fill through the footer too: a black card whose footer stayed grey
            // reads as a bar bolted onto the bottom.
            .background(Color(nsColor: richFill ?? .controlBackgroundColor))
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
        return ColorParser.parse(text)
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

    /// Whether a header bar is pale enough to need dark text. Deliberately higher than the 0.5
    /// mid-point `isLightColor` uses: white still reads better on saturated brand colours such
    /// as Mail's or Xcode's blue, whose luminance drifts just past 0.5 on the green coefficient.
    private func isPaleColor(_ color: Color) -> Bool {
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return true }
        let luminance = 0.2126 * ns.redComponent + 0.7152 * ns.greenComponent + 0.0722 * ns.blueComponent
        return luminance > 0.62
    }

    private func isLightColor(_ color: Color) -> Bool {
        Self.isLight(NSColor(color))
    }

    /// Whether `colour` is light enough that dark text reads better on it.
    static func isLight(_ colour: NSColor) -> Bool {
        guard let ns = colour.usingColorSpace(.deviceRGB) else { return true }
        let luminance = 0.2126 * ns.redComponent
                      + 0.7152 * ns.greenComponent
                      + 0.0722 * ns.blueComponent
        return luminance > 0.5
    }

    /// Footer text colour that stays readable on a card whose footer took a rich fill.
    static func footerTextColor(on fill: NSColor?) -> Color {
        guard let fill else { return .secondary }
        return isLight(fill) ? Color.black.opacity(0.55) : Color.white.opacity(0.7)
    }

    /// Hover-button tint that stays readable on a card whose preview took a rich fill.
    ///
    /// Same shape as `footerTextColor(on:)`, but stronger: these are 11pt glyphs on a translucent
    /// capsule, and on a black card the `.ultraThinMaterial` behind them renders dark grey, which
    /// `.secondary` sinks straight into — the delete button all but vanished. With no fill the
    /// tint stays `.secondary`, exactly as before.
    static func hoverIconColor(on fill: NSColor?) -> Color {
        guard let fill else { return .secondary }
        return isLight(fill) ? Color.black.opacity(0.7) : Color.white.opacity(0.92)
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

/// Pin / share / delete, floating over a card while the pointer is on it.
///
/// Built only while hovered — the card body already re-renders on hover for its ring, so this
/// costs nothing extra when the pointer is elsewhere.
private struct CardHoverActions: View {
    let actions: CardActions
    /// The card's rich fill, or nil when it kept the default background. The icons are tinted
    /// against it so they stay visible on a black card.
    let fill: NSColor?

    private var iconTint: Color { ClipboardItemCard.hoverIconColor(on: fill) }

    var body: some View {
        HStack(spacing: 2) {
            // The pin stays red while unpinned — that colour is what marks the state, and red
            // reads on both a light and a dark fill.
            HoverActionButton(symbol: actions.isPinned ? "pin.slash.fill" : "pin.fill",
                              tint: actions.isPinned ? iconTint : .red,
                              help: actions.isPinned ? "Unpin" : "Pin",
                              action: actions.togglePin)
            HoverActionButton(symbol: "trash", tint: iconTint,
                              help: "Delete", action: actions.delete)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }
}

private struct HoverActionButton: View {
    let symbol: String
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 22, height: 20)
                .background(Circle().fill(hovered ? Color.primary.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// The ⌘-number hint in a card's footer.
///
/// A view of its own, observing `ModifierWatcher` directly, so a modifier press rebuilds only
/// these few labels. Reading the flags through the environment from `ContentView` instead cost
/// a full-panel re-layout on every press (~40ms measured, Release and Debug alike).
private struct ShortcutBadge: View {
    let index: Int
    /// Overridden where the badge sits on a card's own colour rather than on window chrome — a
    /// swatch card, where `.secondary` would go muddy against a saturated fill.
    var tint: Color = .secondary
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
            .foregroundColor(tint)
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
