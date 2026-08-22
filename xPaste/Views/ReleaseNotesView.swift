import SwiftUI

/// The "What's New" box: the release's notes, scrollable, inside a bordered well.
///
/// Takes blocks that have already been parsed rather than raw markdown, so that nothing re-parses
/// the notes on every frame while a download's progress is ticking — see `UpdateWindowView.blocks`.
struct ReleaseNotesView: View {
    let blocks: [ReleaseNoteBlock]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("What's New")
                    .font(.title3).bold()
                    .padding(.bottom, 2)
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    row(for: block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    @ViewBuilder private func row(for block: ReleaseNoteBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(level <= 2 ? .headline : .subheadline).bold()
                .padding(.top, 6)

        case let .paragraph(text):
            Text(inline(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

        case let .bullet(indent, text):
            listRow(marker: "•", markerWidth: 12, indent: indent, text: text)

        case let .ordered(indent, number, text):
            listRow(marker: "\(number).", markerWidth: 22, indent: indent, text: text)

        case let .code(code):
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// One list row. The marker sits right-aligned in a fixed width so every line's text starts at
    /// the same place, two-digit numbers included.
    private func listRow(marker: String, markerWidth: CGFloat, indent: Int,
                         text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: markerWidth, alignment: .trailing)
            Text(inline(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// Inline markdown only — bold, code, links. Malformed markdown makes `AttributedString` throw;
    /// showing the raw text is right there, because losing the sentence never is.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
