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
    /// The search term the card's work was done for. A formatted card bakes the highlight into its
    /// bitmap, so a new term is new work — the same way a light/dark flip is.
    var highlightTerm: String = ""
    /// Which version of the item's content the work was done for.
    ///
    /// The id stays the same when an item is edited, so without this the task never re-runs and the
    /// card keeps every piece of `@State` it derived from the old text — the parsed bitmap, the file
    /// it used to point at, the thumbnail of that file. Purging the shared caches cannot reach any
    /// of those; only re-running the task can.
    var contentRevision: Int = 0
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
    /// The search box's free text, washed yellow wherever it appears on this card. Empty when no
    /// search is running, which is what keeps the attributed-string work off the normal path.
    var highlightTerm: String = ""

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
    /// Which revision of the item's text the state above was derived from, so an edit can be told
    /// apart from a re-run caused by the appearance or the search term.
    @State private var derivedFromRevision: Int?
    @State private var detectedIsDirectory = false
    @State private var fileText: String?
    @AppStorage("linkPreviewEnabled") private var linkPreviewEnabled: Bool = true
    @Environment(\.panelScale) private var panelScale
    /// A rich preview is a baked bitmap, so it belongs to one appearance. Reading the scheme here
    /// makes the card rebuild — rather than keep showing yesterday's white rectangle — when the
    /// system flips between light and dark.
    @Environment(\.colorScheme) private var colorScheme

    /// The card's corner. Shared because the drag image masks itself with the same number — a
    /// mismatch there shows up as the panel's background peeking out of the card's corners.
    static let cornerRadius: CGFloat = 14

    private static var colorCache: [String: Color] = [:]
    private static var iconCache: [String: NSImage] = [:]
    private static var unresolvedBundleIDs: Set<String> = []

    // Count-bounded NSCaches, not plain dicts: keyed by item UUID and written from .task,
    // the old dictionaries were never evicted, so every previewed image (thumbnails up to
    // 1000px + full clipboard images) stayed resident for the whole session even after the
    // item was deleted or history cleared.
    // Bounded by cost as well as by count: these hold decoded pixels, and a thumbnail is built at
    // up to 1000px — four megabytes each, so a hundred and twenty of them is not a bound worth
    // having. See `NSImage.approximateDecodedBytes`.
    private static let pathImageCache: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>()
        c.countLimit = 120
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()
    private static let loadedImageCache: NSCache<NSUUID, NSImage> = {
        let c = NSCache<NSUUID, NSImage>()
        c.countLimit = 120
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()
    /// The opening of each item's file, for the ones that turned out to be text. Bounded like the
    /// image caches, and for the same reason: a card scrolled out of view must not keep its file
    /// resident for the session.
    private static let fileTextCache: NSCache<NSUUID, NSString> = {
        let c = NSCache<NSUUID, NSString>(); c.countLimit = 120; return c
    }()
    /// Rich previews, positive and negative alike: an item that resolved to plain text is stored
    /// as `RichCardPreview.plain` so it is never parsed twice.
    private static let richPreviewCache: NSCache<NSUUID, RichCardPreview> = {
        let c = NSCache<NSUUID, RichCardPreview>(); c.countLimit = 120; return c
    }()
    /// Bounded like its neighbours above, and for the same reason: this one is keyed by file
    /// *path*, not by bundle id, so a plain dictionary grew by one icon for every distinct file
    /// ever shown on a card and never gave one back.
    private static let fileIconCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 200
        c.totalCostLimit = 8 * 1024 * 1024
        return c
    }()

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

    /// Drops everything cached about one item's content, for when that content has been edited.
    ///
    /// All five of these are keyed by the item's id, and an id does not change when its text does.
    /// The card's own `@State` is the sixth cache and cannot be reached from here — that one is
    /// handled by the revision in `CardTaskKey`, which makes `.task` re-run.
    static func forgetContent(for id: UUID) {
        let key = id as NSUUID
        cardTextCache.removeObject(forKey: key)
        richPreviewCache.removeObject(forKey: key)
        fileTextCache.removeObject(forKey: key)
        pathImageCache.removeObject(forKey: key)
        loadedImageCache.removeObject(forKey: key)
    }

    private func fileIcon(_ path: String) -> NSImage {
        if let cached = Self.fileIconCache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        Self.fileIconCache.setObject(icon, forKey: path as NSString,
                                     cost: icon.approximateDecodedBytes)
        return icon
    }

    var body: some View {
        let accent = appAccentColor
        VStack(spacing: 0) {
            cardHeader(accent)
            if contentFlowsUnderFooter {
                // The text owns the whole block and the footer floats over it. Stacking rather
                // than splitting is what lets a long item keep flowing past the character count.
                ZStack(alignment: .bottom) {
                    contentPreview
                    bottomFade
                    footer
                }
            } else {
                contentPreview
                footer
            }
        }
        .frame(width: PanelLayout.cardBaseWidth, height: PanelLayout.cardBaseHeight)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(CardSelectionBorder(itemID: item.id, isHovered: isHovered))
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
        .onHover { isHovered = $0 }
        // Keyed on the appearance as well as the item: `.task(id:)` takes one Equatable value, so
        // the two are combined. A light/dark flip re-runs this and rebuilds the rich preview for
        // the appearance now on screen.
        .task(id: CardTaskKey(itemID: item.id, isLightAppearance: isLightAppearance,
                              highlightTerm: highlightTerm,
                              contentRevision: item.contentRevision)) {
            if item.type == .image {
                if let data = item.imageData, let img = NSImage(data: data) {
                    loadedImage = img
                    Self.loadedImageCache.setObject(img, forKey: item.id as NSUUID,
                                                    cost: img.approximateDecodedBytes)
                } else if item.imageData == nil {
                    loadedImage = await ClipboardStore.shared.loadImage(for: item.id)
                    if let loadedImage {
                        Self.loadedImageCache.setObject(loadedImage, forKey: item.id as NSUUID,
                                                        cost: loadedImage.approximateDecodedBytes)
                    }
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
            // Everything below is derived from the item's text, so an edit invalidates all of it —
            // and a branch that no longer applies would otherwise never run to say so. A card whose
            // path was edited to point somewhere else would keep the old file's thumbnail; a link
            // edited to another address whose fetch then failed would keep the first site's title
            // and picture.
            //
            // Gated on the revision rather than cleared on every pass: this task also re-runs for a
            // light/dark flip and for a new search term, and throwing the thumbnails away for those
            // would flash the card blank and re-decode for nothing.
            if derivedFromRevision != item.contentRevision {
                derivedFromRevision = item.contentRevision
                if pathImage != nil { pathImage = nil }
                if fileText != nil { fileText = nil }
                if richPreview != nil { richPreview = nil }
                if linkPreview != nil { linkPreview = nil }
                if favicon != nil { favicon = nil }
                if linkImageChecked { linkImageChecked = false }
            }

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
                    Self.pathImageCache.setObject(image, forKey: item.id as NSUUID,
                                                  cost: image.approximateDecodedBytes)
                }
            }

            // A file the system had no thumbnail for may still be readable. Skipped when a picture
            // was just decoded — that already answers what the card shows, and the sniff would only
            // read 8KB of JPEG to conclude it is not text.
            if imageURL == nil,
               let textURL = Self.fileTextSource(type: item.type, fileURLs: item.fileURLs,
                                                 detectedPath: resolved.url,
                                                 detectedIsDirectory: resolved.isDir) {
                if let cached = Self.fileTextCache.object(forKey: item.id as NSUUID) {
                    if fileText == nil { fileText = cached as String }
                } else if let text = await Task.detached(priority: .utility, operation: {
                    TextFileReader.read(textURL, maxBytes: 8192)
                }).value {
                    // Capped the same way `cardText` caps an item's own text: a card shows a dozen
                    // lines, and handing `Text` the whole 8KB would re-measure all of it on every
                    // panel re-layout.
                    let capped = String(text.prefix(Self.previewCharLimit))
                    fileText = capped
                    Self.fileTextCache.setObject(capped as NSString, forKey: item.id as NSUUID)
                }
            }

            // Built here, never in `body`: parsing RTF and laying it out is TextKit work, and a
            // card that did it per body pass would re-measure on every panel re-layout.
            if item.carriesRichText,
               item.type == .text || item.type == .url,
               resolved.url == nil,
               detectedColor == nil {
                let light = isLightAppearance
                if let cached = Self.richPreviewCache.object(forKey: item.id as NSUUID),
                   cached.isUsable(underLightAppearance: light, term: highlightTerm,
                                   revision: item.contentRevision) {
                    if richPreview !== cached { richPreview = cached }
                } else {
                    // The default fill is resolved for the appearance on screen, so both the
                    // bitmap's background and the legibility verdict belong to it.
                    let built = await RichTextRenderer.cardPreview(
                        for: item, size: RichTextRenderer.cardPreviewSize,
                        forLightAppearance: light,
                        defaultFill: RichTextRenderer.defaultFill(forLightAppearance: light),
                        highlightTerm: highlightTerm,
                        revision: item.contentRevision)
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
                    domain: linkPreview?.domain,
                    isDirectImage: linkPreview?.isDirectImage ?? false
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
                    nameField(onAccent: onAccent, accent: accent)
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
    private func nameField(onAccent: Color, accent: Color) -> some View {
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
                    selectWholeName(onAccent: onAccent, accent: accent)
                }
            }
    }

    /// Opens the edit with the whole name selected, so the first keystroke replaces it.
    ///
    /// Set explicitly rather than left to SwiftUI, which does select-all itself but only as a side
    /// effect of taking focus — and the field takes focus a runloop turn after it appears, by which
    /// point anything else that touched the field editor would have collapsed it. What is being
    /// replaced is usually a placeholder anyway: an unnamed card seeds the field with its derived
    /// title ("Link", "Text"), which nobody wants to type around.
    ///
    /// The selection is drawn inverted — the header's own two colours, swapped — rather than in the
    /// system's. That colour is a pale wash meant for dark text on a white field, and this title is
    /// white on a saturated header: selecting it painted white on near-white and the name vanished.
    /// `onAccent` was already chosen to read against `accent`, so trading places keeps whatever
    /// contrast the header had.
    private func selectWholeName(onAccent: Color, accent: Color) {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(onAccent),
                .foregroundColor: NSColor(accent),
            ]
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
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
                    if drawsDirectImage {
                        // The picture is the content, not an illustration scraped off a page, so
                        // this is an image card outright — dimensions and all. The size rule below
                        // would park a small or square photograph on the logo plate.
                        imagePreview(img)
                    } else if Self.isLogoSized(img) {
                        logoPreview(img)
                    } else {
                        Image(nsImage: img)
                            .resizable()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if drawsLinkBody {
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
                    } else if let text = resolvedFileText {
                        fileTextPreview(text)
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
            case .color:
                // No file-path branch: a `.color` item's text is always a colour literal — see
                // `ClipboardItem.contentType(for:)` — so it is never also a path to resolve.
                // `detectedColor` is non-nil whenever `item.type == .color`, since it parses the
                // same text this item was classified from; the fallback exists only for parity
                // with the `.text` arm above.
                if let color = detectedColor {
                    colorPreview(color)
                } else {
                    richOrTextPreview
                }
            case .image:
                if let nsImage = loadedImage ?? Self.loadedImageCache.object(forKey: item.id as NSUUID) {
                    imagePreview(nsImage)
                } else {
                    placeholder("photo", color: .purple)
                }
            case .file, .folder:
                if let img = pathImage ?? Self.pathImageCache.object(forKey: item.id as NSUUID) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text = resolvedFileText {
                    fileTextPreview(text)
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
        guard let entry,
              entry.isUsable(underLightAppearance: isLightAppearance, term: highlightTerm,
                             revision: item.contentRevision)
        else { return nil }
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

    /// This card's answer to `ClipboardItemCard.drawsLinkBody`.
    private var drawsLinkBody: Bool {
        Self.drawsLinkBody(previewEnabled: linkPreviewEnabled,
                           hasMetadata: linkPreview != nil,
                           fetchFinished: linkImageChecked)
    }

    /// The fill this card's preview and footer share, or nil to keep the default colours.
    ///
    /// Tied to `drawsRichPreview`, not merely to the cached entry: a card falling back to plain
    /// text must not keep a black fill, or its `labelColor` text would sit on black.
    private var richFill: NSColor? { drawsRichPreview ? resolvedRichPreview?.fill : nil }

    /// Whether this card's content runs on beneath the footer instead of stopping above it.
    ///
    /// Only text does. An image, a file icon or a colour swatch sliding under its own caption
    /// reads as a layout mistake; text running on reads as "there is more of this", which is what
    /// it means, and is how Paste draws the same card.
    ///
    /// The URL clause is `drawsLinkBody`, which covers both reasons a link card stops flowing:
    /// once metadata arrives the footer grows to 52pt and shows a title, and nothing should be
    /// flowing under that; and once the placeholder plate is drawn — including for a URL that
    /// resolved to nothing — the plate has to stop at the strip rather than run beneath it.
    private var contentFlowsUnderFooter: Bool {
        guard item.type == .text || item.type == .url else { return false }
        guard detectedColor == nil, detectedFilePath == nil else { return false }
        if item.type == .url, drawsLinkBody { return false }
        return true
    }

    /// The card's own colour, faded in from nothing over the bottom of the block, so the text
    /// dissolves into the footer rather than being chopped off by it.
    ///
    /// Taller than the footer strip on purpose: the fade has to start well above the character
    /// count, or the last full-strength line sits right against it and the card looks cropped.
    private var bottomFade: some View {
        LinearGradient(
            colors: [Color(nsColor: richFill ?? .textBackgroundColor).opacity(0),
                     Color(nsColor: richFill ?? .textBackgroundColor)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: PanelLayout.cardFooterHeight + 40)
        .allowsHitTesting(false)
    }

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

    /// The opening of a text file, drawn the way a text item is drawn.
    ///
    /// Monospaced: what lands here is JSON, source, config and logs, where the indentation is part
    /// of the meaning. It stops above the footer instead of flowing under it the way `textPreview`
    /// does — this card's footer is the file's path, which is not something to read text through.
    private func fileTextPreview(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(Color(NSColor.labelColor))
            .lineLimit(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
    }

    /// This item's file text, from `@State` or straight from the cache.
    ///
    /// Reads the cache too, for the same reason `resolvedRichPreview` does: a card scrolled back
    /// into view then draws its text on the first body pass rather than one pass later.
    private var resolvedFileText: String? {
        fileText ?? Self.fileTextCache.object(forKey: item.id as NSUUID) as String?
    }

    /// The file whose contents this card should show, or nil to keep the document icon.
    ///
    /// Static so it can be checked directly: the read happens in `.task` while the drawing happens
    /// in `body`, and the two have to agree about which file is on screen.
    static func fileTextSource(type: ClipboardContentType, fileURLs: [URL]?,
                               detectedPath: URL?, detectedIsDirectory: Bool) -> URL? {
        if type == .file, let urls = fileURLs, urls.count == 1 { return urls[0] }
        // A folder has no contents to read, and a multi-file item has no room to say which of them
        // you would be reading.
        if type == .text, let path = detectedPath, !detectedIsDirectory { return path }
        return nil
    }

    /// The wash behind a search hit, taken from the same place the baked bitmaps take theirs so
    /// the two cannot drift into painting different yellows on adjacent cards.
    private var searchHighlightFill: Color {
        Color(nsColor: SearchHighlight.fill(forLightAppearance: isLightAppearance))
    }

    /// `string` as `Text`, with every search hit on a yellow wash.
    ///
    /// Returns `Text` rather than a view so callers keep applying their own font, colour and line
    /// limit exactly as before. With no search running it hands back a plain `Text` and builds no
    /// attributed string at all — the panel's normal state must cost what it always did.
    private func highlighted(_ string: String) -> Text {
        guard !highlightTerm.isEmpty else { return Text(string) }
        let runs = SearchHighlight.split(string, term: highlightTerm)
        guard runs.contains(where: \.isMatch) else { return Text(string) }
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isMatch { piece.backgroundColor = searchHighlightFill }
            result.append(piece)
        }
        return Text(result)
    }

    private var textPreview: some View {
        highlighted(cardText.preview)
            .font(.system(size: 14))
            .foregroundColor(Color(NSColor.labelColor))
            // Ten fills the block now that it reaches the bottom of the card; the last couple of
            // lines land under the fade, which is the point — the text trails off rather than stops.
            .lineLimit(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
    }

    private func colorPreview(_ color: Color) -> some View {
        let tint = Self.onSwatchTint(NSColor(color))
        return ZStack {
            color
            // Upper-cased for the card only — see `ColorParser.displayLiteral`. Pasting still
            // gives back exactly what was copied.
            Text(ColorParser.displayLiteral(item.text ?? ""))
                .font(.system(size: 18, weight: .medium, design: .monospaced))
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

    /// An image card: the picture fitted whole onto an alpha chequerboard, running all the way to
    /// the bottom edge with its pixel dimensions floating over it.
    ///
    /// Fitted, never filled — stretching a square icon across a wider card is the difference the
    /// eye catches first. The chequerboard is what says "these pixels are transparent"; without it
    /// a cut-out logo and a logo on a white plate are the same card.
    private func imagePreview(_ nsImage: NSImage) -> some View {
        ZStack {
            Image(nsImage: Self.checkerboard(light: isLightAppearance))
                .resizable(resizingMode: .tile)
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bottom row occupies exactly the strip a footer would: same height, same 12pt inset.
        // That is what keeps the ⌘-number badge from jumping when the selection moves between an
        // image card and a text one — on both, it ends up on the same line, the same distance in.
        .overlay(alignment: .bottom) {
            ZStack {
                if let px = Self.pixelSize(of: nsImage) {
                    floatingPill {
                        // `verbatim`: interpolating an Int into `Text` formats it for the locale,
                        // and a Vietnamese one turns 3200 into "3.200". Pixel counts are not that
                        // kind of number — nobody groups the digits of an image's width.
                        Text(verbatim: "\(px.width) × \(px.height)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                // Laid out separately from the dimensions rather than beside them, so those stay
                // centred on the card whether or not ⌘ is down instead of sliding left when it is.
                // The badge decides its own visibility — it is what observes the modifier keys.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ShortcutBadge(index: index, tint: .secondary, floating: true)
                        // The pill's own inset comes off the margin: it is the digits that have
                        // to line up with the other cards, not the pill drawn around them.
                        .padding(.trailing, 12 - Self.pillHorizontalInset)
                }
            }
            .frame(height: PanelLayout.cardFooterHeight)
        }
    }

    /// A label that sits on top of a card's own content rather than on a strip of chrome.
    private func floatingPill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Self.pillHorizontalInset)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Self.pillCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial))
    }

    /// How far a floating pill reaches past the text inside it. Shared with the badge, which
    /// subtracts it from its own margin so the digits line up with the other cards.
    fileprivate static let pillHorizontalInset: CGFloat = 9

    /// The corner of a floating pill. Shared with the badge for the same reason as the inset: the
    /// two sit on one line, and a difference between them reads as a mistake rather than a style.
    fileprivate static let pillCornerRadius: CGFloat = 4

    /// Pixel dimensions, read off the bitmap: `NSImage.size` is in points and reports half the
    /// numbers for anything captured on a 2x display.
    private static func pixelSize(of image: NSImage) -> (width: Int, height: Int)? {
        guard let width = image.representations.map(\.pixelsWide).max(),
              let height = image.representations.map(\.pixelsHigh).max(),
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    /// The tiled alpha chequerboard, baked once per appearance.
    ///
    /// Baked rather than drawn in SwiftUI: it never changes, and a `Canvas` per image card would
    /// repaint it on every panel layout — see the note on this file's other caches.
    static func checkerboard(light: Bool) -> NSImage {
        if let cached = checkerboardCache[light] { return cached }
        let square: CGFloat = 8
        let side = square * 2
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        (light ? NSColor(white: 1.00, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
        (light ? NSColor(white: 0.90, alpha: 1) : NSColor(white: 0.24, alpha: 1)).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: square, height: square)).fill()
        NSBezierPath(rect: NSRect(x: square, y: square, width: square, height: square)).fill()
        image.unlockFocus()
        checkerboardCache[light] = image
        return image
    }

    private static var checkerboardCache: [Bool: NSImage] = [:]

    private func placeholder(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 28))
            .foregroundColor(color.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noImagePlaceholder: some View {
        if let fav = favicon {
            logoPreview(fav)
        } else {
            ZStack {
                // Paste puts the tint on the preview and leaves the footer plain; this used to be
                // the other way round, which read as an inverted card next to it.
                mutedBackground
                Image(systemName: Self.placeholderSymbolName)
                    .font(.system(size: 60, weight: .thin))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A logo drawn as one: sitting at icon size on the muted plate rather than stretched across
    /// the card. Shared by the favicon fallback and by the `og:image` that turns out to be an icon,
    /// so a site with both ends up with the same card either way.
    private func logoPreview(_ image: NSImage) -> some View {
        ZStack {
            mutedBackground
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 6, x: 0, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Whether a link that points straight at a picture is drawing as an image card.
    ///
    /// Such a card is an image card in every visible respect — chequerboard, pixel dimensions, no
    /// footer strip — while the item underneath stays a `.url`, so double-clicking it still pastes
    /// the link rather than the picture.
    ///
    /// The image itself has to have arrived. Metadata lands one assignment earlier, and dropping
    /// the footer in that gap leaves a card with no footer and nothing to fill the strip it gave up.
    ///
    /// Static so `contentPreview` and `footer` can switch on the same call: if one of them decided
    /// there was no footer strip while the other drew one, the dimensions pill would land on top of
    /// it — the same trap the `drawsRichPreview` comment describes.
    static func drawsAsImageCard(type: ClipboardContentType,
                                 linkPreviewEnabled: Bool,
                                 preview: LinkPreviewData?) -> Bool {
        type == .url && linkPreviewEnabled
            && preview?.isDirectImage == true && preview?.image != nil
    }

    private var drawsDirectImage: Bool {
        Self.drawsAsImageCard(type: item.type, linkPreviewEnabled: linkPreviewEnabled,
                              preview: linkPreview)
    }

    /// Whether a link's `og:image` is a logo rather than a cover picture.
    /// The glyph on the placeholder plate: a compass, which is what Paste draws and what the plate
    /// means — this is a link, and there is nothing of it to show.
    ///
    /// It replaced a bundled crossed-out photograph captioned "No Preview", which read as something
    /// having gone wrong. Most of the time nothing has: the page simply has no `og:image`.
    static let placeholderSymbolName = "safari"

    /// Whether a URL card's body is a link preview — a picture, a logo plate, or the placeholder
    /// that stands in for one — rather than the URL drawn as text.
    ///
    /// True once the fetch has been and gone, whatever it came back with. `hasMetadata` is taken
    /// and ignored on purpose: it used to be part of this, and requiring it is what put a dead URL
    /// on the plain-text card. A link that resolves to nothing is still a link, gets the same
    /// placeholder plate as a page with no `og:image`, and keeps its text from running on under the
    /// footer — which is what Paste draws for the same item. Keeping the parameter keeps the
    /// caller's question honest: it is asking about a card whose metadata may or may not exist.
    ///
    /// Not the condition `footer` switches on. That one still wants metadata, because without a
    /// title there is nothing for the taller footer to show, and the plain strip with the URL in it
    /// is right — again, what Paste draws.
    static func drawsLinkBody(previewEnabled: Bool, hasMetadata _: Bool, fetchFinished: Bool) -> Bool {
        previewEnabled && fetchFinished
    }

    ///
    /// Two tells, either one enough. Small: a Chrome Web Store listing serves the extension's own
    /// 128px icon under `og:image`, and blowing that up to fill the card is the blurred rectangle
    /// this rule exists to prevent. Square: cover art is cut to 1200×630 and its kin, while icons
    /// and avatars are square — so a square image is a logo whatever its resolution.
    ///
    /// An image with no readable bitmap takes the logo treatment too. Drawing it small costs some
    /// card; drawing it large on a guess costs the thing being fixed here.
    static func isLogoSized(_ image: NSImage) -> Bool {
        guard let px = pixelSize(of: image) else { return true }
        if max(px.width, px.height) < 300 { return true }
        let ratio = Double(px.width) / Double(px.height)
        return ratio > 0.8 && ratio < 1.25
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
        } else if item.type == .image || drawsDirectImage {
            // Same reasoning: the picture runs to the bottom edge and carries its dimensions in a
            // floating pill. A strip here would crop the picture to say "28 KB", which is the one
            // thing about an image nobody is looking for.
            //
            // A link straight to a picture is included: it is showing the picture, so it wants the
            // picture's footer. The URL is still what gets pasted — only the chrome changes.
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
                highlighted(linkPreview?.title ?? item.text ?? "")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .foregroundColor(Color(NSColor.labelColor))
                // The same shape the plain strip writes a URL in — see `urlFooterLabel`. Two link
                // cards side by side, one with a title and one without, cannot disagree about
                // whether a URL has `https://` on the front of it.
                highlighted(Self.urlFooterLabel(item.text ?? ""))
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
            highlighted(path)
                .font(.system(size: 12))
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
        Group {
            if Self.footerAlignsLeading(for: item) {
                // Inline rather than overlaid, unlike the centred case below: a URL fills the
                // strip and has to truncate before the badge instead of running underneath it.
                // The re-centring that overlay exists to prevent cannot happen to a label that
                // starts at the left edge whatever width is left over.
                HStack(spacing: 8) {
                    footerText.frame(maxWidth: .infinity, alignment: .leading)
                    shortcutBadge
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(height: Self.footerHeight(for: item))
            } else {
                footerText
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(height: Self.footerHeight(for: item))
                    // Overlaid rather than placed in an HStack: this label is short and centred, so
                    // it can never collide with the badge, and laying the badge out inline would
                    // re-centre the label in the leftover width — nudging "N characters" left on
                    // every ⌘ press.
                    .overlay(alignment: .trailing) {
                        shortcutBadge.padding(.trailing, 12)
                    }
            }
        }
        // Nothing of its own behind a card whose text flows under it — the gradient below the
        // label is the background, and an opaque strip here would chop the text off again.
        // Elsewhere (an image card) the strip is real: Paste runs the fill through it too,
        // because a black card whose footer stayed grey reads as a bar bolted onto the bottom.
        .background(contentFlowsUnderFooter
                    ? Color.clear
                    : Color(nsColor: richFill ?? .controlBackgroundColor))
    }

    /// The footer's label, before either layout places it.
    ///
    /// Truncated in the middle rather than at the end, because the two ends of a URL are the two
    /// things worth keeping: the site at the front, and whatever distinguishes this page from the
    /// rest of it at the back. The other labels are far too short to ever reach this.
    private var footerText: some View {
        Text(footerLabel)
            .font(.system(size: 12))
            .foregroundColor(Self.footerTextColor(on: richFill))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var footerLabel: String { cardText.footer }

    private var cardText: CardText {
        if let cached = Self.cardTextCache.object(forKey: item.id as NSUUID) { return cached }
        let built = CardText(footer: buildFooterLabel(),
                             preview: String((item.text ?? "").prefix(Self.previewCharLimit)))
        Self.cardTextCache.setObject(built, forKey: item.id as NSUUID)
        return built
    }

    private func buildFooterLabel() -> String { Self.footerLabel(for: item) }

    /// How tall the strip along the bottom of a card is.
    ///
    /// Two points more under a link, because that strip carries a URL rather than a caption: it
    /// runs the full width and uses the full line height, descenders and slashes included, where
    /// "12 KB" sits comfortably inside the default. Only the plain strip is affected — the taller
    /// footer a link with a title gets sets its own 52.
    static func footerHeight(for item: ClipboardItem) -> CGFloat {
        PanelLayout.cardFooterHeight + (footerAlignsLeading(for: item) ? 2 : 0)
    }

    /// Whether the footer label hangs off the left edge instead of sitting under the middle.
    ///
    /// A URL does. It is read left to right and truncates on the right, so it has to start where
    /// reading starts — which is also where Paste puts it. Everything else here is a caption about
    /// the card rather than content of it ("35 characters", "12 KB") and sits under the middle.
    static func footerAlignsLeading(for item: ClipboardItem) -> Bool {
        item.type == .url
    }

    /// A URL as a footer reads it: without the scheme, and without a slash that ends the whole
    /// thing.
    ///
    /// The scheme is chrome — every link has one and it is the same one — and it costs exactly the
    /// width the path needs to stay whole. The path is what tells two links to the same site apart,
    /// so it is never what gets dropped. Anything that is not a URL is left alone: an item can be
    /// typed `.url` and still hold something this cannot parse.
    static func urlFooterLabel(_ raw: String) -> String {
        var text = raw
        if let separator = text.range(of: "://") { text = String(text[separator.upperBound...]) }
        if text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? raw : text
    }

    /// What the strip along the bottom of a card says about its content.
    static func footerLabel(for item: ClipboardItem) -> String {
        switch item.type {
        case .url:
            // The URL, not a count of it. "35 characters" is true of a link and tells its reader
            // nothing they came for, and a link card whose preview failed had nothing else on it —
            // which is what Paste puts here, on every link card, working or not.
            return urlFooterLabel(item.text ?? "")
        case .text, .color:
            // `textLength`, not `text.count`: what the card holds is capped at
            // `ItemEntity.previewCharLimit`, so counting it reported the cap instead of the item
            // for anything longer — every long paste read "4096 characters".
            return "\(item.textLength) characters"
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

    /// The colour this item represents. Gated on the type rather than asking `ColorParser` outright:
    /// the type already answered that question at capture, and this runs on every body pass — which
    /// is the reason `ColorParser` carries a length gate at all.
    private var detectedColor: Color? {
        guard item.type == .color, let text = item.text else { return nil }
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
        case .color:  return "Color"
        case .image:  return "Image"
        case .file:   return "File"
        case .folder: return "Folder"
        }
    }

    var iconName: String {
        switch self {
        case .text:   return "text.alignleft"
        case .url:    return "link"
        case .color:  return "paintpalette"
        case .image:  return "photo"
        case .file:   return "doc.fill"
        case .folder: return "folder.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .text:   return .blue
        case .url:    return Color(red: 0.1, green: 0.6, blue: 0.3)
        // Its own hue, not `.text`'s: that match was pixel parity for the compiler while `.color`
        // was being carved out as a type, and there is no reason left to keep it now that a colour
        // item is never also a `.text` one. `appAccentColor` (this value's only caller) falls back
        // to this only when there is no app icon to sample a real accent from — see
        // `ClipboardItemCard.appAccentColor` — so it rarely paints, but sharing `.text`'s blue in
        // that rare case would read as "this is text", which is exactly the mistake this type
        // exists to stop making.
        case .color:  return .pink
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
    /// Wraps the badge in a translucent pill, for the cards that have no footer strip to put
    /// it on and float it over the picture instead.
    var floating = false
    @ObservedObject private var watcher = ModifierWatcher.shared

    var body: some View {
        if watcher.flags.contains(.command), index <= 9 {
            let label = HStack(spacing: 4) {
                if watcher.flags.contains(.shift) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11))
                }
                Text("\(index)")
                    .font(.system(size: 11))
            }
            .foregroundColor(tint)
            .fixedSize()

            if floating {
                label
                    .padding(.horizontal, ClipboardItemCard.pillHorizontalInset)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: ClipboardItemCard.pillCornerRadius,
                                                 style: .continuous)
                        .fill(.ultraThinMaterial))
            } else {
                label.padding(.leading, 6)
            }
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
        RoundedRectangle(cornerRadius: ClipboardItemCard.cornerRadius, style: .continuous)
            .stroke((isHovered || selection.contains(itemID)) ? Color.accentColor : .clear,
                    lineWidth: 3)
    }
}
