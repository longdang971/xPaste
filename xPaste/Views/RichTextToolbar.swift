import SwiftUI
import AppKit

/// The formatting row above the editor.
///
/// Shown only while editing a Text item — a Link is edited as the address it is, and the other kinds
/// are not editable at all.
///
/// Everything it offers stays inside the popover. `NSFontPanel`, `NSColorPanel` and SwiftUI's
/// `ColorPicker` are all deliberately unused: each is a separate window, a separate window takes key
/// status, and the panel's glass follows the key window — so the panel dims behind whichever one is
/// open. That was measured once already, when the delete confirmation moved to a window of its own.
struct RichTextToolbar: View {
    @ObservedObject var session: EditSession

    @State private var linkRowShown = false
    @State private var address = ""

    private var editingSource: Bool { session.mode == .raw }

    /// Pulled out of `controls` (rather than left as an inline `Image(systemName:)` literal) so a
    /// test can assert against the same value the view actually draws, instead of a copy that
    /// could silently drift from it.
    static let clearFormattingSymbol = "eraser"

    var body: some View {
        VStack(spacing: 0) {
            controls
            if linkRowShown { linkRow }
        }
        // `RichTextToolbar` is not rebuilt on a mode switch — only `editor` is, keyed on
        // `session.generation` in `ItemPreviewWindow` — so this row's own @State would otherwise
        // survive into raw mode. Left open, its TextField and Apply/Remove would stay live there,
        // unlike every other control in `controls`, which the link *button* included is disabled
        // for raw mode. Closing it on any mode change keeps that same rule for the row itself.
        .onChange(of: session.mode) { _ in linkRowShown = false }
        // `address` is otherwise only ever written when the link button is pressed, but the
        // Apply/Update label and the Remove button's enabled state both track `session.state.link`
        // live as the caret moves. Left unsynced, the field can go on showing link A's address while
        // the button now reads "Update" for link B (or "Apply" for plain text) — pressing it then
        // writes A's address onto whatever is under the caret now. Re-seeding here keeps the field
        // and the button telling the same story. This does not fight the user mid-edit: typing in
        // the field never moves the caret in the text view, so `session.state.link` cannot change
        // out from under a keystroke here the way it can when the user clicks elsewhere.
        .onChange(of: session.state.link) { newLink in
            address = newLink?.absoluteString ?? ""
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            traitButton("bold", command: .bold, on: session.state.bold, help: "Bold")
            traitButton("italic", command: .italic, on: session.state.italic, help: "Italic")
            traitButton("underline", command: .underline, on: session.state.underline,
                        help: "Underline")
            traitButton("strikethrough", command: .strikethrough, on: session.state.strikethrough,
                        help: "Strikethrough")

            divider

            fontMenu
            sizeMenu

            divider

            Button {
                // Pre-filled from the link under the caret, so an address that is already there is
                // something to correct rather than something to retype.
                address = session.state.link?.absoluteString ?? ""
                linkRowShown.toggle()
            } label: {
                Image(systemName: "link").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(editingSource)
            .help("Link")
            .accessibilityLabel("Link")

            Button { session.run(.clearFormatting) } label: {
                Image(systemName: Self.clearFormattingSymbol).font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(editingSource)
            .help("Clear formatting")
            .accessibilityLabel("Clear formatting")

            Spacer()

            Button { session.toggleMode() } label: {
                Image(systemName: editingSource
                      ? "textformat"
                      : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(editingSource ? "Show formatted text" : "Show HTML source")
            .accessibilityLabel(editingSource ? "Show formatted text" : "Show HTML source")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// A row inside the popover, not a sheet and not a window: a window would take key status and
    /// the panel's glass follows the key window, so the panel would dim behind it.
    private var linkRow: some View {
        HStack(spacing: 6) {
            TextField("https://", text: $address)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit(applyLink)

            Button(session.state.link == nil ? "Apply" : "Update", action: applyLink)
                .controlSize(.small)
                .disabled(!Self.isLinkableAddress(address))

            Button("Remove") {
                session.run(.link(nil))
                linkRowShown = false
            }
            .controlSize(.small)
            .disabled(session.state.link == nil)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func applyLink() {
        // Repeats the `disabled` check above rather than trusting it: `.onSubmit` on the TextField
        // also calls this, and Return fires regardless of whether the button was ever enabled.
        guard Self.isLinkableAddress(address),
              let url = URL(string: address.trimmingCharacters(in: .whitespaces))
        else { return }
        session.run(.link(url))
        linkRowShown = false
    }

    /// Whether `address` is safe to turn into a `.link` run.
    ///
    /// Mirrors `ClipboardItem.contentType(for:)`, which allows only `http` and `https` because those
    /// are the schemes the app treats as safe to hand to the system — see its comment. This row adds
    /// `mailto:` on top: an email address is an ordinary thing to link to, and `mailto:` is no more
    /// dangerous than the other two. What both lists exclude is the point — `javascript:` and
    /// `file:` addresses `URL(string:)` accepts happily, and before this row existed there was no
    /// way for a user to type an arbitrary address and have it become a link at all.
    static func isLinkableAddress(_ address: String) -> Bool {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)) else { return false }
        return url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto"
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
    }

    /// Lit when the trait is on throughout the selection, so a lit button always says what pressing
    /// it again would do.
    private func traitButton(_ symbol: String,
                             command: RichTextCommand,
                             on: Bool,
                             help: String) -> some View {
        Button { session.run(command) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on && !editingSource ? Color.accentColor.opacity(0.25) : Color.clear))
        }
        .buttonStyle(.plain)
        .disabled(editingSource)
        .help(help)
        .accessibilityLabel(help)
    }

    private var familyLabel: String { Self.familyLabel(for: session.state.family) }

    /// A mixed selection must not fall back to "System": that was the defect here — a selection
    /// spanning two named families (Helvetica and Times, say), neither of them the system face, read
    /// as `nil` under the old `String?` and rendered as "System", which was true of nothing in the
    /// selection. "–" matches `sizeLabel`'s own mixed reading below — a screen-reader user who has
    /// learned what "–" means from one menu should not have to learn a second spelling for the other.
    ///
    /// Pulled out as a `static func` (rather than left as the `private var` this used to be) so
    /// `RichTextToolbarTests` can exercise the `.mixed` case without a live `EditSession` — see the
    /// file header comment on why nothing else here is reachable from an XCTest target.
    static func familyLabel(for family: RichTextFamily) -> String {
        switch family {
        case .system:          return "System"
        case .named(let name): return name
        case .mixed:           return "–"
        }
    }

    /// No single number when the selection mixes sizes — a tick on one of them would be a claim
    /// about the rest that is not true. Same pull-out-for-testing reasoning as `familyLabel(for:)`.
    static func sizeLabel(for size: CGFloat?) -> String {
        size.map { String(Int($0)) } ?? "–"
    }

    private var fontMenu: some View {
        Menu {
            Button("System") { session.run(.family(nil)) }
            Divider()
            ForEach(FontCatalogue.weights, id: \.name) { entry in
                Button(entry.name) { session.run(.weight(entry.weight)) }
            }
            Divider()
            ForEach(FontCatalogue.families, id: \.self) { family in
                Button(family) { session.run(.family(family)) }
            }
        } label: {
            Text(familyLabel)
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(editingSource)
        .help("Font")
        .accessibilityLabel("Font")
        // The visible text doubling as this control's title is not something to depend on: it is
        // AppKit mirroring whatever string the label happens to render, which is exactly what let
        // the size menu next to this one go silent — the same shape of label, but nothing declared
        // as its accessible value, so VoiceOver had nothing reliable to read. Declaring the value
        // explicitly (here and on `sizeMenu`) makes both controls announce label-then-value the same,
        // documented way instead of one working by accident.
        .accessibilityValue(familyLabel)
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(FontCatalogue.sizes, id: \.self) { size in
                Button(String(Int(size))) { session.run(.size(size)) }
            }
        } label: {
            Text(Self.sizeLabel(for: session.state.size))
                .font(.system(size: 11))
                .frame(width: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(editingSource)
        .help("Size")
        .accessibilityLabel("Size")
        // See the matching comment on `fontMenu`: this is the actual fix for the size menu not
        // announcing its value — declare it, rather than hope the rendered text gets picked up.
        .accessibilityValue(Self.sizeLabel(for: session.state.size))
    }

}

/// What the menus offer.
///
/// The family list is built once and held: `availableFontFamilies` is several hundred entries and
/// SwiftUI builds a `Menu`'s items eagerly, so re-deriving it per body pass would put that walk on
/// every keystroke.
enum FontCatalogue {
    static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    static let sizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 18, 24, 36, 48]

    static let weights: [(name: String, weight: NSFont.Weight)] = [
        ("Light", .light), ("Regular", .regular), ("Semibold", .semibold), ("Bold", .bold),
    ]


}
