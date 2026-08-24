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

    private var editingSource: Bool { session.mode == .raw }

    var body: some View {
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

            colourMenu(symbol: "textformat", help: "Text colour",
                       swatches: FontCatalogue.textColours,
                       clearTitle: "Automatic") { .foreground($0) }
            colourMenu(symbol: "highlighter", help: "Highlight",
                       swatches: FontCatalogue.highlightColours,
                       clearTitle: "None") { .background($0) }

            divider

            Button { session.run(.clearFormatting) } label: {
                Image(systemName: "textformat.size.smaller").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(editingSource)
            .help("Clear formatting")

            Spacer()

            Button { session.toggleMode() } label: {
                Image(systemName: editingSource
                      ? "textformat"
                      : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help(editingSource ? "Show formatted text" : "Show HTML source")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            Text(session.state.familyName ?? "System")
                .font(.system(size: 11))
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(editingSource)
        .help("Font")
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(FontCatalogue.sizes, id: \.self) { size in
                Button(String(Int(size))) { session.run(.size(size)) }
            }
        } label: {
            // No single number when the selection mixes sizes — a tick on one of them would be a
            // claim about the rest that is not true.
            Text(session.state.size.map { String(Int($0)) } ?? "–")
                .font(.system(size: 11))
                .frame(width: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(editingSource)
        .help("Size")
    }

    private func colourMenu(symbol: String,
                            help: String,
                            swatches: [(name: String, colour: NSColor)],
                            clearTitle: String,
                            command: @escaping (NSColor?) -> RichTextCommand) -> some View {
        Menu {
            Button(clearTitle) { session.run(command(nil)) }
            Divider()
            ForEach(swatches, id: \.name) { swatch in
                Button {
                    session.run(command(swatch.colour))
                } label: {
                    Label {
                        Text(swatch.name)
                    } icon: {
                        Image(systemName: "square.fill").foregroundStyle(Color(nsColor: swatch.colour))
                    }
                }
            }
        } label: {
            Image(systemName: symbol).font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(editingSource)
        .help(help)
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

    static let textColours: [(name: String, colour: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple),
        ("Pink", .systemPink), ("Brown", .systemBrown), ("Grey", .systemGray),
        ("Black", NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)),
        ("White", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)),
    ]

    /// Light washes, all of them. A highlight has to stay a highlight rather than become a block of
    /// colour, and `RichTextCommand.background` pins the text dark so these read in either
    /// appearance.
    static let highlightColours: [(name: String, colour: NSColor)] = [
        ("Yellow", NSColor(srgbRed: 1.00, green: 0.95, blue: 0.55, alpha: 1)),
        ("Green",  NSColor(srgbRed: 0.75, green: 0.95, blue: 0.75, alpha: 1)),
        ("Blue",   NSColor(srgbRed: 0.75, green: 0.88, blue: 1.00, alpha: 1)),
        ("Pink",   NSColor(srgbRed: 1.00, green: 0.80, blue: 0.88, alpha: 1)),
        ("Orange", NSColor(srgbRed: 1.00, green: 0.85, blue: 0.65, alpha: 1)),
        ("Grey",   NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1)),
    ]
}
