import SwiftUI
import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// Whether a key press is the one that opens and closes the item preview.
///
/// Space cannot be a key equivalent on either side of this. Opening, a hidden button in the panel
/// only resolves once first responder is back from whatever was last up. Closing, a text preview
/// hands first responder to its `NSTextView` (measured: `firstResponder` is `IBeamTextView` with
/// the popover up) and a text view treats a plain space as its own — it scrolls a page and
/// swallows the event. So the decision is made in `AppDelegate`'s key monitor, which sees the
/// press before any window dispatches it and does not care which window is key.
enum PreviewSpaceKey {
    static let spaceKeyCode: UInt16 = 49

    /// `firstResponder` is whatever holds focus at the moment of the press. Editable text is the
    /// one thing a space still belongs to — but only once something has been typed into it.
    ///
    /// `inPanel` says the press was dispatched to the panel itself. The panel's one editable field
    /// is the search box: a card being renamed, the item editor and the delete confirmation all
    /// raise the alert handshake, which the key monitor has already stood down for before it asks
    /// this. So an empty editable field here is an empty search box, and a space at the front of
    /// an empty query means nothing to search for.
    ///
    /// That case is not a corner: the search box keeps first responder after the filter sheet
    /// closes over it — AppKit hands the panel's responder back when the popover's window gives up
    /// key — while the user is looking at cards, not at a query. Measured with the field editor
    /// logged on every press: every space after that sheet closed went into the search box, and
    /// the preview stopped answering Space entirely.
    /// `webFieldFocused` is the same exemption as the editable-text one below, for a responder
    /// that cannot be recognised by its class. A link preview is a `WKWebView`, and a text field
    /// inside the page it is showing is not an `NSText` — it is not an `NSResponder` at all, it is
    /// a DOM node. So a space typed into a search box on the page read as "nothing is being
    /// edited" and shut the preview instead of being typed. The page reports its own focus; see
    /// `WebTextFocus`.
    static func togglesPreview(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                               firstResponder: NSResponder?, inPanel: Bool,
                               webFieldFocused: Bool = false) -> Bool {
        guard keyCode == spaceKeyCode else { return false }
        // Caps Lock is not a binding anyone makes, so it is not treated as a modifier here.
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard mods.isEmpty else { return false }
        if webFieldFocused { return false }
        if let text = firstResponder as? NSText, text.isEditable {
            return inPanel && text.string.isEmpty
        }
        return true
    }
}

struct PreviewPopoverContent: View {
    let item: ClipboardItem
    var onClose: () -> Void

    @State private var loadedImage: NSImage?
    @State private var richPreview: RichFullPreview?
    @State private var fileText: String?
    /// The picture behind a single image file, at full size. See `loadFileImageIfNeeded`.
    @State private var fileImage: NSImage?
    /// What the filesystem says about the one file or folder this preview is showing.
    @State private var fileFacts: FileFacts?
    /// The tags and cover art behind a single sound file. Nil for everything else.
    @State private var audioInfo: MediaInfo?
    /// Which player this file gets, once AVFoundation has said it can play it at all.
    @State private var mediaKind: MediaKind?
    /// Whether that question has been answered yet. Separate from `mediaKind` because "not a media
    /// file" and "not asked yet" are the same nil and must not draw the same thing.
    @State private var mediaChecked = false
    /// Counted once in `.task`, not per body pass: three full walks of the string measured 50ms on
    /// a 468KB item, and the popover re-renders several times while it settles.
    @State private var stats = ""
    /// The item's whole text, fetched once when the popover appears.
    ///
    /// `item.text` is capped at `ItemEntity.previewCharLimit` — it is what a card draws and what
    /// search matches, not the item. This window is where someone comes to read the whole thing,
    /// so showing the cap here meant a long paste appeared to end at 4096 characters, with the
    /// footer agreeing that it did.
    @State private var wholeText: String?
    @Environment(\.colorScheme) private var colorScheme

    /// The text to show, count and share: the whole of it once it has arrived, the prefix until
    /// then. Never `item.text` directly.
    private var shownText: String? { wholeText ?? item.text }

    private var title: String {
        switch item.type {
        case .url:    return "Link"
        case .color:  return "Color"
        case .image:  return "Image"
        case .file, .folder:
            // Plural and counted, because for a multi-file item that count is the first thing
            // worth knowing and the pane below is a list rather than one file.
            let n = item.fileURLs?.count ?? 0
            if n > 1 { return item.type == .folder ? "\(n) Folders" : "\(n) Files" }
            return item.type == .folder ? "Folder" : "File"
        case .text:   return "Text"
        }
    }

    private var itemURL: URL? {
        guard item.type == .url, let text = item.text else { return nil }
        return URL(string: text)
    }

    /// One size for everything except a web page.
    ///
    /// It used to be three: 420x340 for a text item, 560x440 for a link, 560x460 once the pencil
    /// was pressed. So opening a preview and choosing Edit resized the window under the pointer,
    /// and the text reflowed into a different shape at the moment the user was about to work on
    /// it. Everything took the editor's size, because the editor was the one that had to be big
    /// enough.
    ///
    /// The editor has since moved into a window of its own — see `EditWindow` — so nothing
    /// reshapes under the pointer any more, and the rule can stop paying for a problem that no
    /// longer exists. Only the page gets the exception: a web page is the one thing here laid out
    /// for a browser rather than for this window, and 560pt of it is a column of wrapped
    /// fragments. Text, pictures, colours and files are all shown at their own size inside the
    /// box, so a bigger box would only be emptier.
    private var previewSize: CGSize {
        if item.type == .url, itemURL != nil {
            return Self.pagePreviewSize(fitting: NSScreen.main?.visibleFrame.size)
        }
        if item.type == .file || item.type == .folder { return Self.filePreviewSize }
        return Self.defaultPreviewSize
    }

    static let defaultPreviewSize = CGSize(width: 560, height: 460)

    /// A file preview gets a tenth more than the default.
    ///
    /// A tenth, and written as a tenth rather than as 616x506, because that is what it is: a
    /// nudge, not a size arrived at on its own. Everything on this pane is laid out by the pane —
    /// the picture, the icon and its facts, the list of names — so it all takes the extra rather
    /// than leaving it as margin, which is why it is worth giving and why the default is still
    /// the right size for a colour swatch or a line of text.
    static let filePreviewScale: CGFloat = 1.1

    static var filePreviewSize: CGSize {
        CGSize(width: (defaultPreviewSize.width * filePreviewScale).rounded(),
               height: (defaultPreviewSize.height * filePreviewScale).rounded())
    }

    /// As much of `pagePreviewIdeal` as the screen will take.
    ///
    /// Clamped rather than fixed, for the reason `PanelLayout.minScale` exists: the panel runs
    /// along one edge of the screen and this is anchored to a card inside it, so on a 13" laptop a
    /// 660pt-tall popover has nowhere to go and AppKit would shunt it somewhere of its own
    /// choosing. The margins taken off are what the panel and the menu bar occupy.
    ///
    /// It never shrinks below the size every other preview gets. A screen too small for that is
    /// a screen the popover was already too big for.
    static func pagePreviewSize(fitting screen: CGSize?) -> CGSize {
        guard let screen else { return defaultPreviewSize }
        return CGSize(
            width: min(pagePreviewIdeal.width, max(defaultPreviewSize.width, screen.width - 120)),
            height: min(pagePreviewIdeal.height, max(defaultPreviewSize.height, screen.height - 420))
        )
    }

    static let pagePreviewIdeal = CGSize(width: 900, height: 660)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            previewFooter
        }
        .frame(width: previewSize.width, height: previewSize.height)
        // Keyed on the appearance as well as the item, the same way the card is: the legibility
        // guard resolves against `textBackgroundColor`, so a popover left open across a light/dark
        // flip would otherwise keep a verdict that no longer matches what is behind it.
        .task(id: CardTaskKey(itemID: item.id, isLightAppearance: colorScheme == .light)) {
            await loadImageIfNeeded()
            // Parsed here, not in `body`: a large RTF re-parsed per body pass would stutter the
            // popover for nothing.
            if item.type == .text || item.type == .url {
                richPreview = RichTextRenderer.fullPreview(for: item)
            }
            // Facts first: whether the file is a picture is what decides between reading it as
            // text and decoding it as an image, and both of those are disk work worth not doing.
            await loadFileFactsIfNeeded()
            await resolveMediaKindIfNeeded()
            await loadAudioInfoIfNeeded()
            await loadFileImageIfNeeded()
            await loadFileTextIfNeeded()
            // `.color` shares the footer's character count with `.text` (see the `previewFooter`
            // switch below), so it needs the same stats computed here.
            if item.isTextTruncated, wholeText == nil {
                wholeText = ClipboardStore.shared.fullText(for: item)
            }
            if (item.type == .text || item.type == .color), stats.isEmpty {
                let text = shownText ?? item.displayText
                stats = await Task.detached(priority: .userInitiated) {
                    Self.textStats(text)
                }.value
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            if ItemEdit.canEdit(item.type) {
                Button {
                    onClose()
                    EditWindowPresenter.shared.present(item)
                } label: {
                    Image(systemName: "pencil").font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Edit")
            }
            shareControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var shareControl: some View {
        if let url = itemURL {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13))
            }
            .buttonStyle(.plain)
        } else if (item.type == .text || item.type == .color), let text = shownText {
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .url:
            if let url = itemURL { WebPreview(url: url) } else { textContent }
        case .image:
            imageContent
        case .text, .color:
            textContent
        case .file, .folder:
            fileContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if let rich = richPreview {
            RichTextPreview(text: rich.text, fill: rich.fill)
        } else {
            plainTextContent
        }
    }

    /// Plain text goes through the same `NSTextView` the formatted and file panes use.
    ///
    /// It used to be a SwiftUI `Text` in a `ScrollView`, which lays the whole string out at once —
    /// exactly what the file pane below already avoids for the same reason, in its own words. A
    /// half-megabyte note is a normal thing to copy and this is the pane you open to read it.
    private var plainTextContent: some View {
        RichTextPreview(text: Self.plainBody(shownText ?? item.displayText), fill: nil)
    }

    private static func plainBody(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    @ViewBuilder
    private var imageContent: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable().interpolation(.high).scaledToFit().padding(12)
            } else {
                ProgressView()
            }
        }
    }

    /// The file pane: one file shown as itself, several shown as a list.
    ///
    /// It used to be one shape for both — a stack of name rows, each with its own Reveal button,
    /// and the file's text underneath when there was one. That shape said the same thing about a
    /// screenshot as about a folder: here is a filename. A single item is the thing you pressed
    /// Space to look at, so it gets the pane; the list is for when there is more than one and the
    /// question is which.
    @ViewBuilder
    private var fileContent: some View {
        if let urls = item.fileURLs, urls.count > 1 {
            fileListContent(urls)
        } else if let url = item.fileURLs?.first {
            singleFileContent(url)
        } else {
            // A file item whose paths did not survive the store. Nothing to draw and nothing to
            // reveal, but the pane still has to be something.
            ZStack {
                Color(nsColor: .textBackgroundColor)
                Text("No files").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    /// One file or folder, shown as whatever it is: the picture, the text, or the icon.
    @ViewBuilder
    private func singleFileContent(_ url: URL) -> some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            if mediaKind == .video {
                // Edge to edge, the way every other video on the Mac is shown, with the controls
                // floating over the picture rather than taking a strip out of the pane.
                VideoPreviewPane(url: url)
            } else if mediaKind == .audio {
                AudioPreviewPane(url: url, info: audioInfo)
            } else if !mediaChecked, MediaFile.kind(of: url) != nil {
                // Deciding. Blank rather than the icon pane, which would appear for a moment and
                // then be replaced by the player — a flash on every song opened.
                Color.clear
            } else if let fileImage {
                // The same treatment an `.image` item gets, because at this size that is what the
                // user opened the pane to see. `.high` interpolation matters here and nowhere else:
                // a screenshot scaled down to fit 560pt is resampled, not merely drawn.
                Image(nsImage: fileImage)
                    .resizable().interpolation(.high).scaledToFit().padding(12)
            } else if let fileText {
                // The same `NSTextView` the text items use, rather than a `Text` in a `ScrollView`:
                // this pane holds up to 256KB, which TextKit pages and SwiftUI would lay out whole.
                RichTextPreview(text: Self.monospaced(fileText), fill: nil)
            } else {
                fileHero(url)
            }
        }
    }

    /// A file with nothing to show of itself — an app, an archive, a folder — drawn the way the
    /// Finder's own Get Info draws one: its icon at size, its name, and one line of facts.
    private func fileHero(_ url: URL) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFit().frame(width: 128, height: 128)
            Text(url.lastPathComponent)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if let subtitle = fileFacts?.subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    /// Several files: one row each, name over the folder it came from.
    ///
    /// The path is the second line rather than a tooltip because that is the whole question a
    /// multi-file item raises — two files with the same name are the ordinary case, not the corner.
    /// Keyed by position, not by URL: the same path can legitimately appear twice.
    private func fileListContent(_ urls: [URL]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 13)).lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    if index < urls.count - 1 {
                        // Inset to clear the icon column, so the divider separates the names rather
                        // than cutting the icons off from them.
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Monospaced because what lands here is JSON, source, config and logs, where the indentation
    /// carries meaning that a proportional font throws away.
    private static func monospaced(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
    }

    /// The file behind a single-file item, read only if it turns out to be text.
    ///
    /// Far more than the card reads: this pane scrolls, so it can show a whole config file rather
    /// than its opening. Multi-file items are left alone — there is no room to say which file the
    /// pane belongs to, and a picture is skipped because it already has a pane of its own.
    private func loadFileTextIfNeeded() async {
        guard item.type == .file, let urls = item.fileURLs, urls.count == 1, fileText == nil,
              fileFacts?.isImage != true, MediaFile.kind(of: urls[0]) == nil
        else { return }
        let url = urls[0]
        fileText = await Task.detached(priority: .userInitiated) {
            TextFileReader.read(url, maxBytes: 262_144)
        }.value
    }

    /// The single file or folder's size, kind and — for a picture — its pixel dimensions.
    ///
    /// Off the main actor: `resourceValues` and a directory listing both hit the disk, and this
    /// pane appears under a key press.
    private func loadFileFactsIfNeeded() async {
        guard item.type == .file || item.type == .folder,
              let urls = item.fileURLs, urls.count == 1, fileFacts == nil
        else { return }
        let url = urls[0]
        fileFacts = await Task.detached(priority: .userInitiated) { FileFacts.read(url) }.value
    }

    /// Whether this file gets a player, and which.
    private func resolveMediaKindIfNeeded() async {
        guard !mediaChecked, let url = item.fileURLs?.first, item.fileURLs?.count == 1 else {
            mediaChecked = true
            return
        }
        mediaKind = await MediaFile.playableKind(of: url)
        mediaChecked = true
    }

    /// The cover art and tags behind a single sound file.
    ///
    /// Only for sound: a video's pane is `AVPlayerView`, which reads the file itself, and parsing
    /// its metadata here would open a second handle on it for nothing.
    private func loadAudioInfoIfNeeded() async {
        guard let url = item.fileURLs?.first, mediaKind == .audio, audioInfo == nil
        else { return }
        audioInfo = await MediaFile.readAudio(url)
    }

    /// The picture behind a single image file.
    ///
    /// Capped at 2000 pixels on the long edge rather than decoded whole: the pane is 560pt wide,
    /// and a 48-megapixel photograph decoded at full size to be drawn a twentieth that big is
    /// hundreds of megabytes resident for as long as the popover is up.
    private func loadFileImageIfNeeded() async {
        guard fileFacts?.isImage == true, fileImage == nil,
              let url = item.fileURLs?.first
        else { return }
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2000,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
        if let cgImage { fileImage = NSImage(cgImage: cgImage, size: .zero) }
    }


    @ViewBuilder
    private var previewFooter: some View {
        HStack {
            switch item.type {
            case .text, .color:
                Text(stats).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            case .url:
                if let url = itemURL {
                    Text(url.absoluteString)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Open in \(DefaultBrowser.name(for: url))") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
            case .image:
                if let loadedImage {
                    Text("\(Int(loadedImage.size.width)) × \(Int(loadedImage.size.height))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            case .file, .folder:
                let urls = item.fileURLs ?? []
                // The path for one file, the count for several — the same split the pane above
                // makes, and for the same reason: with one file the path is what identifies it,
                // and with several the list already carries every path there is.
                Text(urls.count == 1 ? urls[0].path : ClipboardItemCard.footerLabel(for: item))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let detail = fileFacts?.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !urls.isEmpty {
                    // Every URL at once, so revealing a multi-file item selects the whole set in
                    // Finder rather than making the user come back for the next one.
                    //
                    // And the bar goes with it. Finder comes forward, so leaving the panel up
                    // parks it over the window the user was sent to — the same reason the editor
                    // hides it on the way to opening.
                    //
                    // Hiding the panel is the whole of it: `.panelWillHide` already closes this
                    // popover — see `ContentView`'s handler, which calls `preview.close()`.
                    // Closing it here as well made the popover go first and the bar follow, which
                    // reads as the panel shutting twice.
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                        NotificationCenter.default.post(name: .hidePanelRequested, object: nil)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// Pure, and `nonisolated` so the detached task that calls it is not hopping back to the
    /// main actor to count the characters of a document — which is the whole reason that call is
    /// detached.
    nonisolated private static func textStats(_ text: String) -> String {
        let chars = text.count
        let words = text.split { $0 == " " || $0.isNewline }.filter { !$0.isEmpty }.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        return "\(chars) characters · \(words) words · \(lines) lines"
    }


    private func loadImageIfNeeded() async {
        guard item.type == .image, loadedImage == nil else { return }
        // The original, not the card's thumbnail. This window is where someone goes to actually
        // look at the picture, and the thumbnail can be a quality-0.10 JPEG — or scaled down
        // outright — for exactly the large screenshots most worth opening full size.
        if let img = await ClipboardStore.shared.loadOriginalImage(for: item) {
            loadedImage = img
        } else if let data = item.imageData, let img = NSImage(data: data) {
            loadedImage = img
        }
    }
}

/// What the preview pane can say about a single file or folder without opening it.
///
/// A value rather than three pieces of `@State`, so the pane can never be drawn having learned the
/// size but not yet whether the thing is a picture — which is the difference between the image pane
/// and the icon one.
struct FileFacts: Sendable {
    /// The system's own name for the type: "PNG image", "Application", "Folder".
    var kind: String
    /// The short fact for the footer: a byte count, an item count, or a picture's dimensions.
    var detail: String
    /// Whether this is a picture, and so whether the pane draws it rather than reading it.
    var isImage: Bool

    /// Kind and detail on one line, for the icon pane's subtitle.
    var subtitle: String {
        [kind, detail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Reads them off the filesystem. Pure disk work with no main-actor state, so it is called from
    /// a detached task — see `loadFileFactsIfNeeded`.
    static func read(_ url: URL) -> FileFacts {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey,
                                         .isDirectoryKey, .isPackageKey, .contentTypeKey]
        let values = try? url.resourceValues(forKeys: keys)
        let kind = values?.localizedTypeDescription ?? ""

        // A package is a directory only to the filesystem. Counting its contents said
        // "Application · 1 item" under Xcode.app, which is true of the folder and nonsense about
        // the app — the one thing inside it is `Contents`. Its kind is the whole answer.
        if values?.isPackage == true { return FileFacts(kind: kind, detail: "", isImage: false) }

        if values?.isDirectory == true {
            // The immediate contents, not a recursive count: this is a caption, and walking a home
            // folder to write one would take longer than the popover stays up.
            let n = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
            let detail = n.map { "\($0) item\($0 == 1 ? "" : "s")" } ?? ""
            return FileFacts(kind: kind, detail: detail, isImage: false)
        }

        let bytes = (values?.fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? ""
        let isImage = values?.contentType?.conforms(to: .image) ?? false
        // Read from the file's metadata rather than by decoding it: the dimensions are in the
        // header, and this runs before anything has decided to decode anything.
        if isImage, let size = pixelSize(of: url) {
            let dimensions = "\(size.width) × \(size.height)"
            return FileFacts(kind: kind,
                             detail: bytes.isEmpty ? dimensions : "\(dimensions) · \(bytes)",
                             isImage: true)
        }
        return FileFacts(kind: kind, detail: bytes, isImage: isImage)
    }

    private static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

/// The editor itself: the same `NSTextView` the preview already uses, told it is editable.
///
/// Seeded once in `makeNSView` and never written to again — `updateNSView` deliberately does
/// nothing, because pushing the seed back in on a SwiftUI update would throw away what the user has
/// typed and move the caret back to the start.
struct EditableRichText: NSViewRepresentable {
    let initial: NSAttributedString
    let allowsFormatting: Bool
    let monospaced: Bool
    let fill: NSColor?
    /// Hands the freshly built view to `EditSession.attach(_:)`, which wires it up as the live
    /// editor and reports its state — see that method for why this view cannot just be handed to
    /// `EditBuffer` directly and left at that.
    let onAttach: (NSTextView) -> Void
    let onChange: () -> Void
    let onSelectionChange: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = makeScrollableTextView()
        scroll.drawsBackground = true

        view.isEditable = true
        view.isSelectable = true
        view.isRichText = allowsFormatting
        view.allowsUndo = true
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 14, height: 14)
        view.delegate = context.coordinator
        view.textStorage?.setAttributedString(initial)
        if !allowsFormatting {
            // A plain item is edited plain, so nothing pasted into the editor can smuggle
            // formatting into an item that never had any. Raw mode gets the monospaced face for the
            // same reason the file pane does: what it shows is source, and its nesting carries
            // meaning a proportional font throws away.
            view.font = monospaced ? .monospacedSystemFont(ofSize: 12, weight: .regular)
                                   : .systemFont(ofSize: 13)
            view.textColor = .labelColor
        }

        let colour = fill ?? .textBackgroundColor
        scroll.backgroundColor = colour
        view.backgroundColor = colour

        onAttach(view)
        // Next turn: the view is not in a window yet while `makeNSView` runs, so there is nothing
        // to become first responder of.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onSelectionChange: onSelectionChange, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: () -> Void
        let onSelectionChange: () -> Void
        let onCancel: () -> Void

        init(onChange: @escaping () -> Void,
             onSelectionChange: @escaping () -> Void,
             onCancel: @escaping () -> Void) {
            self.onChange = onChange
            self.onSelectionChange = onSelectionChange
            self.onCancel = onCancel
        }

        func textDidChange(_ notification: Notification) {
            onChange()
            onSelectionChange()
        }

        /// What lights the toolbar's buttons: clicking through mixed formatting has to move them.
        func textViewDidChangeSelection(_ notification: Notification) {
            onSelectionChange()
        }

        /// Escape reaches here rather than AppDelegate's monitor because entering edit mode posts
        /// the alert handshake, which stops the monitor swallowing it.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            onCancel()
            return true
        }
    }
}

/// An `NSTextView` that keeps the I-beam over its text even though xPaste is never the active app.
///
/// The panel is a `nonactivatingPanel` and `showPanel` never calls `NSApp.activate` — that is the
/// whole point of it, and it means whatever the user was working in stays frontmost. But the cursor
/// rects AppKit sets for a selectable text view are only honoured for the *active* application, so
/// the pointer stayed an arrow over text that could be selected and typed into. A tracking area
/// marked `.activeAlways` is what still gets a say when the app is not the one in front.
final class IBeamTextView: NSTextView {
    private static let marker = "xPaste.iBeam"

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.userInfo?[Self.marker] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: [Self.marker: true]))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }
}

/// A scrollable `IBeamTextView`, assembled by hand because `NSTextView.scrollableTextView()` can
/// only ever build a plain `NSTextView`.
func makeScrollableTextView() -> (scroll: NSScrollView, text: IBeamTextView) {
    let scroll = NSScrollView()
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true

    let huge: CGFloat = .greatestFiniteMagnitude
    let container = NSTextContainer(size: NSSize(width: 0, height: huge))
    container.widthTracksTextView = true
    let layout = NSLayoutManager()
    layout.addTextContainer(container)
    let storage = NSTextStorage()
    storage.addLayoutManager(layout)

    let text = IBeamTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100),
                             textContainer: container)
    text.autoresizingMask = [.width]
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.minSize = NSSize(width: 0, height: 0)
    text.maxSize = NSSize(width: huge, height: huge)
    scroll.documentView = text
    return (scroll, text)
}

/// Whether the page inside a link preview has the caret in one of its own fields.
///
/// A flag rather than something derived on demand, because the one reader is `AppDelegate`'s key
/// monitor: it has to answer before the event is dispatched, and asking a `WKWebView` what has
/// focus means running JavaScript, which is asynchronous. So the page reports it as it happens and
/// this holds the answer.
///
/// Main thread only, and unannotated for it, like the panel's other small singletons: every writer
/// is a `WKScriptMessageHandler` callback and every reader is a key monitor or the hide path, all
/// of which AppKit runs on main. `@MainActor` would put the read behind an `await` in exactly the
/// place that cannot wait.
final class WebTextFocus {
    static let shared = WebTextFocus()
    private(set) var isEditing = false
    private init() {}

    func set(_ editing: Bool) { isEditing = editing }
    /// Called when a preview goes away. A flag left true would swallow every space afterwards.
    func clear() { isEditing = false }
}

private struct WebPreview: NSViewRepresentable {
    let url: URL

    /// Reports whether what has focus in the page is something you type into.
    ///
    /// `focusout` is reported on the next tick, because at the moment it fires `activeElement` is
    /// still the element being left. Injected into every frame, so a search box inside an iframe
    /// counts as well as one in the page itself.
    private static let focusReporter = """
    (function () {
      function editable(el) {
        if (!el) return false;
        if (el.isContentEditable) return true;
        var tag = el.tagName;
        if (tag === 'TEXTAREA') return true;
        if (tag !== 'INPUT') return false;
        var type = (el.type || 'text').toLowerCase();
        return ['button', 'checkbox', 'radio', 'submit', 'reset', 'file', 'range', 'color',
                'image'].indexOf(type) === -1;
      }
      function report() {
        window.webkit.messageHandlers.\(WebPreview.focusHandlerName)
          .postMessage(editable(document.activeElement));
      }
      document.addEventListener('focusin', report, true);
      document.addEventListener('focusout', function () { setTimeout(report, 0); }, true);
      report();
    })();
    """

    private static let focusHandlerName = "xPasteWebFocus"

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(
            WKUserScript(source: Self.focusReporter, injectionTime: .atDocumentEnd,
                         forMainFrameOnly: false))
        config.userContentController.add(context.coordinator, name: Self.focusHandlerName)
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// The handler is retained by the content controller, which the web view owns — so it has to be
    /// taken off by hand or the coordinator outlives every preview ever opened.
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController
            .removeScriptMessageHandler(forName: focusHandlerName)
        web.stopLoading()
        WebTextFocus.shared.clear()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            WebTextFocus.shared.set(message.body as? Bool ?? false)
        }
    }
}

/// A read-only `NSTextView` showing an item's formatted text.
///
/// TextKit directly rather than the card's cached bitmap: here the text has to be selectable and
/// scrollable, and only one popover exists at a time, so fidelity beats the bitmap's speed.
private struct RichTextPreview: NSViewRepresentable {
    let text: NSAttributedString
    let fill: NSColor?

    func makeNSView(context: Context) -> NSScrollView {
        let (scroll, view) = makeScrollableTextView()
        scroll.drawsBackground = true
        do {
            view.isEditable = false
            view.isSelectable = true
            view.drawsBackground = true
            view.textContainerInset = NSSize(width: 14, height: 14)
            view.textStorage?.setAttributedString(text)
        }
        apply(to: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let view = scroll.documentView as? NSTextView,
           view.textStorage?.isEqual(to: text) == false {
            view.textStorage?.setAttributedString(text)
        }
        apply(to: scroll)
    }

    private func apply(to scroll: NSScrollView) {
        let colour = fill ?? .textBackgroundColor
        scroll.backgroundColor = colour
        (scroll.documentView as? NSTextView)?.backgroundColor = colour
    }
}
