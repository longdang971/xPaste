import SwiftUI
import AppKit
import WebKit

/// Whether a key press should close the item preview.
///
/// Space opens the preview from the bar, so space is what a user reaches for to put it away —
/// and for a text item it did nothing. The popover's own hidden `.keyboardShortcut(.space)`
/// button never resolved, because a text preview hands first responder to its `NSTextView`
/// (measured: `firstResponder` is `IBeamTextView` with the popover up) and a text view treats a
/// plain space as its own — it scrolls a page and swallows the event. The bar's space button,
/// one window up, never saw it either. So the decision is made from a key monitor instead, which
/// runs before the window dispatches the event to anything.
enum PreviewSpaceKey {
    static let spaceKeyCode: UInt16 = 49

    /// `firstResponder` is whatever holds focus at the moment of the press. Editable text is the
    /// one thing a space still belongs to: the search box, a card being renamed, the editor.
    static func closes(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       firstResponder: NSResponder?) -> Bool {
        guard keyCode == spaceKeyCode else { return false }
        // Caps Lock is not a binding anyone makes, so it is not treated as a modifier here.
        let mods = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        guard mods.isEmpty else { return false }
        if let text = firstResponder as? NSText, text.isEditable { return false }
        return true
    }
}

/// Watches for that space for as long as the preview is on screen.
///
/// A local monitor, not a global one: this is xPaste's own key press. It is torn down both when
/// the popover disappears and in `deinit`, because a monitor left behind would keep eating spaces
/// with nothing left to close — the shape of a leak this app has been bitten by before.
final class PreviewSpaceMonitor: ObservableObject {
    private var monitor: Any?

    func start(onClose: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard PreviewSpaceKey.closes(keyCode: event.keyCode,
                                         modifiers: event.modifierFlags,
                                         firstResponder: event.window?.firstResponder)
            else { return event }
            onClose()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

struct PreviewPopoverContent: View {
    let item: ClipboardItem
    var onClose: () -> Void

    @State private var loadedImage: NSImage?
    @State private var richPreview: RichFullPreview?
    @State private var fileText: String?
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
    /// See `PreviewSpaceKey`: the space that closes this window cannot be a key equivalent.
    @StateObject private var spaceMonitor = PreviewSpaceMonitor()
    @Environment(\.colorScheme) private var colorScheme

    /// The text to show, count and share: the whole of it once it has arrived, the prefix until
    /// then. Never `item.text` directly.
    private var shownText: String? { wholeText ?? item.text }

    private var title: String {
        switch item.type {
        case .url:    return "Link"
        case .color:  return "Color"
        case .image:  return "Image"
        case .file:   return "File"
        case .folder: return "Folder"
        case .text:   return "Text"
        }
    }

    private var itemURL: URL? {
        guard item.type == .url, let text = item.text else { return nil }
        return URL(string: text)
    }

    /// One size, whatever the popover is showing.
    ///
    /// It used to be three: 420x340 for a text item, 560x440 for a link, 560x460 once the pencil
    /// was pressed. So opening a preview and choosing Edit resized the window under the pointer,
    /// and the text reflowed into a different shape at the moment the user was about to work on
    /// it. The editor's size is the one that has to be big enough, so it is the one everything
    /// else takes.
    private var previewWidth: CGFloat { 560 }
    private var previewHeight: CGFloat { 460 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            previewFooter
        }
        .frame(width: previewWidth, height: previewHeight)
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
        .onAppear { spaceMonitor.start(onClose: onClose) }
        .onDisappear { spaceMonitor.stop() }
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

    private var fileContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(item.fileURLs ?? [], id: \.self) { url in
                HStack(spacing: 10) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 26, height: 26)
                    Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.small)
                }
            }
            if let fileText {
                Divider()
                // The same `NSTextView` the text items use, rather than a `Text` in a `ScrollView`:
                // this pane holds up to 256KB, which TextTkit pages and SwiftUI would lay out whole.
                RichTextPreview(text: Self.monospaced(fileText), fill: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, -14)
                    .padding(.bottom, -14)
            } else {
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    /// pane belongs to.
    private func loadFileTextIfNeeded() async {
        guard item.type == .file, let urls = item.fileURLs, urls.count == 1, fileText == nil
        else { return }
        let url = urls[0]
        fileText = await Task.detached(priority: .userInitiated) {
            TextFileReader.read(url, maxBytes: 262_144)
        }.value
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
                let n = (item.fileURLs ?? []).count
                Text(item.type == .folder ? "\(n) folder(s)" : "\(n) file(s)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
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

private struct WebPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.load(URLRequest(url: url))
        return web
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
