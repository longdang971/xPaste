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
}
