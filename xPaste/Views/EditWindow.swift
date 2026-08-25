import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// The editor is opening and wants the bar out of the way.
    static let hidePanelForEditing = Notification.Name("com.user.xPaste.hidePanelForEditing")
}

/// The editor, in a window of its own.
///
/// It used to live inside the preview popover, and that is where a whole class of bugs came from.
/// A popover is anchored to a card inside the bar, so its life is tangled with the bar's: hiding
/// the bar left it on screen with its parent gone — no longer key, no first responder, clicks no
/// longer moving the caret — and nothing on it could close it, because its own close button ran the
/// same SwiftUI state change that had already failed to reach it. Worse, a second editor could open
/// on top of the first: measured, a click landed on the older one while the newer was what the user
/// could see, so a colour chosen for the visible selection was applied to the hidden document and
/// only appeared once the top one was closed.
///
/// A real window owned by this presenter has none of that. There is exactly one, it is closed by
/// closing it, and it does not care what the bar does.
///
/// Non-activating and key: it needs the keyboard for typing, but taking it must not pull the user
/// out of the application they are about to paste into — the same trade the bar itself makes.
@MainActor
final class EditWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = EditWindowPresenter()

    private var panel: NSPanel?
    /// Held here rather than as SwiftUI `@StateObject`. One window, one session, for as long as the
    /// window is up — which is the guarantee the popover could not make.
    private var session: EditSession?
    /// The other half: a colour item has no document, so it goes through this instead — see
    /// `ColourDraft`.
    private var colourDraft: ColourDraft?
    private var colourTarget: ColourPanelTarget?
    private var literalObserver: AnyCancellable?
    /// True while a change is coming *out* of the picker, so pushing it back in is skipped.
    private var applyingFromPicker = false
    private var editingItemID: UUID?

    private override init() { super.init() }

    var isOpen: Bool { panel != nil }
    /// Whether the system colour picker is currently wired to this presenter. `NSColorPanel` does
    /// not expose its target, so the answer has to come from here.
    var isColourPickerAttached: Bool { colourTarget != nil }

    func present(_ item: ClipboardItem) {
        dismiss()
        guard ItemEdit.canEdit(item.type) else { return }

        // The bar goes away first. It keeps the editor from sitting on top of the very cards it
        // came from, and it sidesteps the glass: the bar's Liquid Glass follows its window's key
        // state, so a key editor in front of a visible bar darkens it — the trap the delete
        // confirmation documents at length.
        NotificationCenter.default.post(name: .hidePanelForEditing, object: nil)

        // The whole text, never the prefix a card carries: what the editor holds becomes the item.
        let hydrated = ClipboardStore.shared.hydrated(item)
        self.editingItemID = item.id

        let hosting: NSHostingView<AnyView>
        let size: NSSize
        if item.type == .color {
            let draft = ColourDraft(literal: hydrated.text ?? "")
            self.colourDraft = draft
            hosting = NSHostingView(rootView: AnyView(ColourEditView(
                draft: draft,
                onCancel: { [weak self] in self?.dismiss() },
                onSave: { [weak self] in self?.save() })))
            size = Self.colourWindowSize
        } else {
            let session = EditSession()
            session.begin(with: ItemEdit.editorSeed(for: hydrated, parsed: nil).text)
            self.session = session
            hosting = NSHostingView(rootView: AnyView(EditWindowView(
                item: hydrated,
                session: session,
                onCancel: { [weak self] in self?.dismiss() },
                onSave: { [weak self] in self?.save() })))
            size = Self.windowSize
        }
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = EditPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // A stable mark so a test can count what is actually on screen without depending on the
        // hosting view's generic parameter, which changes with what is being edited.
        panel.identifier = Self.windowIdentifier
        panel.delegate = self
        panel.center(onScreen: NSApp.keyWindow?.screen ?? NSScreen.main)

        self.panel = panel
        // Tells AppDelegate's monitors to keep their hands off: while this is up, Escape belongs to
        // the editor and the panel's own shortcuts must stay out of the way.
        NotificationCenter.default.post(name: .clipboardAlertShown, object: nil)
        panel.makeKeyAndOrderFront(nil)
        if let colourDraft { openColourPanel(for: colourDraft) }
    }

    /// The system colour picker, alongside the editor.
    ///
    /// `RichTextToolbar` documents at length why `NSColorPanel` was refused for text colours: it is
    /// a separate window, a separate window takes key, and the bar's Liquid Glass follows the key
    /// window and visibly dims behind it. That reasoning does not reach here — the editor is a
    /// window of its own now and the bar is already hidden behind it, so there is no glass left to
    /// dim.
    private func openColourPanel(for draft: ColourDraft) {
        let target = ColourPanelTarget { [weak self, weak draft] colour in
            guard let self, let draft else { return }
            self.applyingFromPicker = true
            draft.take(colour)
            self.applyingFromPicker = false
        }
        colourTarget = target

        let picker = NSColorPanel.shared
        picker.setTarget(target)
        picker.setAction(#selector(ColourPanelTarget.colourChanged(_:)))
        picker.isContinuous = true
        picker.showsAlpha = false
        // Level, and this is what made it look as though it never opened at all: measured, the
        // shared panel sits at `.floating` (3) while the editor is at `.statusBar + 1` (26). It was
        // being ordered front the whole time — behind the editor, and behind every other floating
        // window on screen. Matching the editor's level is what puts it where the user is looking.
        picker.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        picker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // xPaste is an accessory and loses front constantly; without this the picker would vanish
        // the moment the user's own application came back.
        picker.hidesOnDeactivate = false
        if let colour = draft.colour { picker.color = colour }
        picker.orderFront(nil)

        // Typing in the field moves the wheel, so the two never disagree about what colour is being
        // edited. Guarded against the round trip: a change that came *from* the wheel is not pushed
        // back into it.
        literalObserver = draft.$literal
            .receive(on: RunLoop.main)
            .sink { [weak self] literal in
                guard let self, !self.applyingFromPicker,
                      let colour = ColorParser.parse(literal).map({ NSColor($0) })
                else { return }
                let picker = NSColorPanel.shared
                if picker.color != colour { picker.color = colour }
            }
    }

    private func closeColourPanel() {
        guard colourTarget != nil else { return }
        colourTarget = nil
        literalObserver?.cancel()
        literalObserver = nil
        let picker = NSColorPanel.shared
        // Only ours is torn down: leaving the target set would have the panel go on messaging a
        // draft that no longer exists the next time anything opened it.
        picker.setTarget(nil)
        picker.setAction(nil)
        picker.orderOut(nil)
    }

    func dismiss() {
        closeColourPanel()
        guard let panel else { return }
        self.panel = nil
        session = nil
        colourDraft = nil
        editingItemID = nil
        panel.delegate = nil
        panel.orderOut(nil)
        NotificationCenter.default.post(name: .clipboardAlertHidden, object: nil)
    }

    private func save() {
        guard let id = editingItemID else { return }
        if let colourDraft {
            guard colourDraft.colour != nil else { return }
            ClipboardStore.shared.updateContent(id: id, text: colourDraft.literal,
                                                richData: nil, richType: nil)
            dismiss()
            return
        }
        guard let session else { return }
        guard let draft = session.resolvedDraft() else {
            session.error = "That HTML could not be read."
            return
        }
        let plain = draft.string
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.error = "There is nothing to save."
            return
        }
        // Never the editor's *permission* to format — what decides is whether the saved text
        // differs from the defaults it opened with. See `ItemEdit.carriesFormatting`.
        let rich = ItemEdit.carriesFormatting(draft) ? ItemEdit.rtf(from: draft) : nil
        ClipboardStore.shared.updateContent(id: id, text: plain, richData: rich,
                                            richType: rich == nil ? nil : ItemEdit.richType)
        dismiss()
    }

    func windowWillClose(_ notification: Notification) { dismiss() }

    static let windowIdentifier = NSUserInterfaceItemIdentifier("xPaste.editorWindow")

    static let windowSize = NSSize(width: 620, height: 480)
    /// Shorter: a colour has one line to show, not a document.
    static let colourWindowSize = NSSize(width: 460, height: 320)
}

/// Takes the keyboard without activating the app, exactly as the bar does.
private final class EditPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private extension NSWindow {
    func center(onScreen screen: NSScreen?) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                               y: visible.minY + (visible.height - frame.height) * 0.6))
    }
}

/// The editor's chrome: Cancel and Save flanking the formatting row, the document, and a count.
///
/// Shaped after Paste's own editor — a floating rounded slab rather than a titled window, so it
/// reads as part of the same family as the bar.
struct EditWindowView: View {
    let item: ClipboardItem
    @ObservedObject var session: EditSession
    let onCancel: () -> Void
    let onSave: () -> Void

    @State private var draftIsEmpty = false
    @State private var stats = ""
    @State private var colourDraft = ""
    /// The link the editor is holding right now, if what is in it is one.
    ///
    /// Taken from the live text rather than from `item`: an edit that turns prose into an address
    /// makes a Link card on save, so the button has to appear at the moment the text becomes one —
    /// and go away again if it stops being one. `ClipboardItem.contentType` is what decides, so
    /// this and the card can never disagree about what counts as a link.
    @State private var draftURL: URL?

    private var editingColour: Bool { item.type == .color }
    private var editingSource: Bool { session.mode == .raw }

    var body: some View {
        VStack(spacing: 0) {
            chrome
            document
            statsRow
        }
        .background(PanelGlassBackground(cornerRadius: Self.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .task { recount(session.buffer.plain.isEmpty ? item.text ?? "" : session.buffer.plain) }
        .background {
            // ⌘S saves. A hidden button rather than `.defaultAction`, which would also claim Return
            // — and Return in an editor is a new line.
            Button("") { onSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draftIsEmpty)
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var chrome: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)
            if ItemEdit.keepsFormatting(item) {
                RichTextToolbar(session: session)
            }
            Spacer(minLength: 4)

            Button(action: onSave) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .background(Capsule().fill(draftIsEmpty ? Color.gray : Color.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(draftIsEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var document: some View {
        VStack(spacing: 0) {
            if editingColour, !editingSource {
                ColorEditRow(text: colourDraft) { session.replaceAll(with: $0) }
                Divider()
            }
            editor
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var editor: some View {
        let generation = session.generation
        return EditableRichText(
            initial: session.seed,
            allowsFormatting: session.mode == .formatted && ItemEdit.keepsFormatting(item),
            monospaced: session.mode == .raw,
            fill: nil,
            onAttach: { session.attach($0) },
            onChange: {
                guard session.generation == generation else { return }
                let plain = session.buffer.plain
                let empty = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if empty != draftIsEmpty { draftIsEmpty = empty }
                if editingColour { colourDraft = plain }
                recount(plain)
            },
            onSelectionChange: { session.refreshState(ifCurrent: generation) },
            onCancel: onCancel
        )
        // A mode switch is a rebuild, not an update — see `EditSession`.
        .id(generation)
    }

    private var statsRow: some View {
        HStack(spacing: 6) {
            if let error = session.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
            } else {
                Text(stats).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let url = draftURL {
                Button("Open in \(DefaultBrowser.name(for: url))") {
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func recount(_ text: String) {
        stats = Self.describe(text)
        let next = Self.link(in: text)
        if next != draftURL { draftURL = next }
    }

    /// The address in `text`, or nil when it is not one.
    ///
    /// Gated on `ClipboardItem.contentType` rather than on `URL(string:)` alone, which succeeds on
    /// almost any string: only what the app would file as a Link counts, which is `http` and
    /// `https` — the schemes something can actually be opened at.
    static func link(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClipboardItem.contentType(for: trimmed) == .url else { return nil }
        return URL(string: trimmed)
    }

    /// "17 characters · 1 words · 1 lines", the way Paste counts them.
    static func describe(_ text: String) -> String {
        let words = text.split { $0 == " " || $0.isNewline }.filter { !$0.isEmpty }.count
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        return "\(text.count) characters  ·  \(words) words  ·  \(lines) lines"
    }

    private static let cornerRadius: CGFloat = 20
}


/// The application that would open a link, by name — "Open in Safari", "Open in Google Chrome".
///
/// Shared by the editor's footer and the preview's, so the two never name it differently.
enum DefaultBrowser {
    static func name(for url: URL) -> String {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "Browser" }
        return FileManager.default.displayName(atPath: app.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Colour items

/// The literal being edited, as the colour panel moves it.
///
/// Colour items do not go through `EditSession`: there is no document to type into, and the value
/// arrives from a system panel rather than a keyboard. Keeping them on their own model is what lets
/// the editor show a swatch where a text view would be, without pretending a hidden text view is
/// still the source of truth.
@MainActor
final class ColourDraft: ObservableObject {
    /// Always a literal in the notation the item arrived in — see `ColourDraft.format`.
    @Published var literal: String

    /// The notation to write back in, read from what is in the field right now.
    ///
    /// Derived rather than fixed at init, because the field is editable: an item copied as
    /// `rgb(30, 144, 255)` is saved as one, and a user who types `#1e90ff` over it gets hex back
    /// from the wheel rather than having their notation rewritten on the next drag.
    var format: ColorFormat { Self.format(of: literal) }

    init(literal: String) {
        self.literal = literal
    }

    var colour: NSColor? { ColorParser.parse(literal).map { NSColor($0) } }

    func take(_ colour: NSColor) {
        literal = format.render(colour)
    }

    static func format(of literal: String) -> ColorFormat {
        let lower = literal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("rgb") { return .rgb }
        if lower.hasPrefix("hsl") { return .hsl }
        return .hex
    }

    /// "RGB 255, 255, 255  ·  HSL 0, 0, 100  ·  HSB 0, 0, 100" — every reading at once, the way
    /// Paste puts them under the swatch.
    static func readings(for colour: NSColor) -> String {
        guard let c = colour.usingColorSpace(.sRGB) else { return "" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let hsl = ColorFormat.hsl.render(colour)
            .replacingOccurrences(of: "%", with: "")
            .drop { $0 != "(" }.dropFirst().dropLast()
        // Red comes back as a hue of 1.0, i.e. 360 — the same angle as 0, and 0 is what every
        // colour tool writes. Wrapping keeps the reading from flipping between the two ends of the
        // wheel for the same colour.
        let hue = Int((c.hueComponent * 360).rounded()) % 360
        let sat = Int((c.saturationComponent * 100).rounded())
        let bri = Int((c.brightnessComponent * 100).rounded())
        return "RGB \(r), \(g), \(b)  ·  HSL \(hsl)  ·  HSB \(hue), \(sat), \(bri)"
    }
}

/// The editor for a colour: the colour itself, its literal, and the system picker.
struct ColourEditView: View {
    @ObservedObject var draft: ColourDraft
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            chrome
            ColorEditRow(text: draft.literal) { draft.literal = $0 }
            swatch
            footer
        }
        .background(PanelGlassBackground(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        .background {
            Button("") { onSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(draft.colour == nil)
                .opacity(0).frame(width: 0, height: 0)
        }
    }

    private var chrome: some View {
        HStack {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: onSave) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .background(Capsule().fill(draft.colour == nil ? Color.gray : Color.accentColor))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(draft.colour == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var swatch: some View {
        ZStack {
            (draft.colour.map { Color(nsColor: $0) } ?? Color(nsColor: .textBackgroundColor))
            // A field, not a label: the code is the item, and typing over it is how someone
            // nudges a colour by hand rather than hunting for it on the wheel. Shown exactly as it
            // is stored — the card's upper-casing is a card thing, and rewriting what someone is
            // halfway through typing would fight them.
            TextField("", text: $draft.literal)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(draft.colour.map { ClipboardItemCard.onSwatchTint($0) }
                                 ?? Color(nsColor: .labelColor))
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                // White is a colour someone copies, and a white swatch on a light window needs an
                // edge to read against at all.
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack {
            Text(draft.colour.map(ColourDraft.readings) ?? "Not a colour")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

/// Receives the system colour panel's changes. `NSColorPanel` speaks target/action, which needs an
/// `NSObject` to speak to.
@MainActor
final class ColourPanelTarget: NSObject {
    private let onPick: (NSColor) -> Void
    init(onPick: @escaping (NSColor) -> Void) { self.onPick = onPick }

    @objc func colourChanged(_ sender: NSColorPanel) { onPick(sender.color) }
}
