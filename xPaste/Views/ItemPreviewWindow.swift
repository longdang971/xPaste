import SwiftUI
import AppKit
import WebKit

struct PreviewPopoverContent: View {
    let item: ClipboardItem
    /// Open straight into edit mode, for the card menu's "Edit…".
    var startEditing: Bool = false
    var onClose: () -> Void

    @State private var loadedImage: NSImage?
    @State private var richPreview: RichFullPreview?
    @State private var fileText: String?
    @State private var isEditing = false
    /// Whether what is in the editor right now is nothing but whitespace, which is the one thing
    /// Save refuses. Kept as its own flag and assigned only when it changes, so typing does not
    /// re-render the popover on every keystroke.
    @State private var draftIsEmpty = false
    /// Holds a weak reference to the live text view, so the draft is read once on Save rather than
    /// copied out of the editor on every keystroke.
    @State private var buffer = EditBuffer()
    /// Counted once in `.task`, not per body pass: three full walks of the string measured 50ms on
    /// a 468KB item, and the popover re-renders several times while it settles.
    @State private var stats = ""
    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        if isEditing { return "Edit" }
        switch item.type {
        case .url:    return "Link"
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

    private var previewWidth: CGFloat { item.type == .url ? 560 : 420 }
    private var previewHeight: CGFloat { item.type == .url ? 440 : 340 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
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
            if item.type == .text, stats.isEmpty {
                let text = item.displayText
                stats = await Task.detached(priority: .userInitiated) {
                    Self.textStats(text)
                }.value
            }
        }
        .onAppear { if startEditing { setEditing(true) } }
        // Whatever takes the popover away — Save, Cancel, the panel hiding, the item being
        // deleted — the handshake has to be undone. Left set, `alertIsPresented` stays true in
        // AppDelegate and Escape stops closing the panel for the rest of the session.
        .onDisappear { setEditing(false) }
        .background {
            // Space closes the preview, but while editing it is a character the user is typing.
            Button("") { onClose() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(isEditing)
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    // MARK: - Editing

    /// Borrows the alert handshake that renaming uses, so `AppDelegate`'s key monitor stops
    /// swallowing Escape — while the editor is up, Escape must cancel the edit rather than close
    /// the panel out from under it.
    private func setEditing(_ editing: Bool) {
        guard isEditing != editing else { return }
        isEditing = editing
        NotificationCenter.default.post(
            name: editing ? .clipboardAlertShown : .clipboardAlertHidden, object: nil)
        if editing { draftIsEmpty = false }
    }

    private var editor: some View {
        let seed = ItemEdit.editorSeed(for: item, parsed: richPreview?.text)
        return EditableRichText(
            initial: seed.text,
            allowsFormatting: seed.formatted,
            fill: seed.formatted ? richPreview?.fill : nil,
            buffer: buffer,
            onChange: {
                let empty = buffer.plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if empty != draftIsEmpty { draftIsEmpty = empty }
            },
            onCancel: { setEditing(false) }
        )
    }

    /// Writes the edit and closes.
    ///
    /// Closing rather than returning to the preview because `item` is a value captured when this
    /// view was built: it still holds the old content, so staying open would show the text the
    /// edit has just replaced. The card behind the popover updates from the store.
    private func save() {
        let plain = buffer.plain
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Never `seed.formatted` — that only says the editor *allowed* formatting, which is now
        // true of every Text item. What decides is whether the saved text differs from the
        // defaults it opened with.
        let rich = ItemEdit.carriesFormatting(buffer.attributed) ? ItemEdit.rtf(from: buffer.attributed) : nil
        ClipboardStore.shared.updateContent(id: item.id, text: plain,
                                            richData: rich,
                                            richType: rich == nil ? nil : ItemEdit.richType)
        setEditing(false)
        onClose()
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
            if !isEditing, ItemEdit.canEdit(item.type) {
                Button { setEditing(true) } label: {
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
        } else if item.type == .text, let text = item.text {
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            editor
        } else {
            switch item.type {
            case .url:
                if let url = itemURL { WebPreview(url: url) } else { textContent }
            case .image:
                imageContent
            case .text:
                textContent
            case .file, .folder:
                fileContent
            }
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
        RichTextPreview(text: Self.plainBody(item.displayText), fill: nil)
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
    private var footer: some View {
        if isEditing {
            editingFooter
        } else {
            previewFooter
        }
    }

    private var editingFooter: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { setEditing(false) }
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            // ⌘S, the key everyone reaches for. It does not collide with the panel's own ⌘S
            // (save to a file) because entering edit mode raises the alert handshake, which stops
            // AppDelegate's key monitor claiming the keystroke at all.
            Button("Save") { save() }
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draftIsEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var previewFooter: some View {
        HStack {
            switch item.type {
            case .text:
                Text(stats).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            case .url:
                if let url = itemURL {
                    Text(url.absoluteString)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Open in \(browserName(for: url))") { NSWorkspace.shared.open(url) }
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

    private static func textStats(_ text: String) -> String {
        let chars = text.count
        let words = text.split { $0 == " " || $0.isNewline }.filter { !$0.isEmpty }.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        return "\(chars) characters · \(words) words · \(lines) lines"
    }

    private func browserName(for url: URL) -> String {
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Browser" }
        return FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func loadImageIfNeeded() async {
        guard item.type == .image, loadedImage == nil else { return }
        if let data = item.imageData, let img = NSImage(data: data) {
            loadedImage = img
        } else {
            loadedImage = await ClipboardStore.shared.loadImage(for: item.id)
        }
    }
}

/// A handle on the live editor.
///
/// Holds the text view weakly and reads it on demand, rather than copying the document out on every
/// keystroke — a large snippet would otherwise be duplicated per character typed.
final class EditBuffer {
    weak var textView: NSTextView?

    var plain: String { textView?.string ?? "" }
    var attributed: NSAttributedString { textView?.attributedString() ?? NSAttributedString() }
}

/// The editor itself: the same `NSTextView` the preview already uses, told it is editable.
///
/// Seeded once in `makeNSView` and never written to again — `updateNSView` deliberately does
/// nothing, because pushing the seed back in on a SwiftUI update would throw away what the user has
/// typed and move the caret back to the start.
private struct EditableRichText: NSViewRepresentable {
    let initial: NSAttributedString
    let allowsFormatting: Bool
    let fill: NSColor?
    let buffer: EditBuffer
    let onChange: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }

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
            // formatting into an item that never had any.
            view.font = .systemFont(ofSize: 13)
            view.textColor = .labelColor
        }

        let colour = fill ?? .textBackgroundColor
        scroll.backgroundColor = colour
        view.backgroundColor = colour

        buffer.textView = view
        // Next turn: the view is not in a window yet while `makeNSView` runs, so there is nothing
        // to become first responder of.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onCancel: onCancel) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let onChange: () -> Void
        let onCancel: () -> Void

        init(onChange: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.onChange = onChange
            self.onCancel = onCancel
        }

        func textDidChange(_ notification: Notification) { onChange() }

        /// Escape reaches here rather than AppDelegate's monitor because entering edit mode posts
        /// the alert handshake, which stops the monitor swallowing it.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            onCancel()
            return true
        }
    }
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
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        if let view = scroll.documentView as? NSTextView {
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
