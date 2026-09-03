import SwiftUI
import AppKit

/// The filters the query could become, drawn under the search field.
///
/// One panel with a rule between the rows rather than a stack of separate pills: the rows are one
/// list to pick from, and each pill carrying its own outline and shadow read as several unrelated
/// things that happened to land under the field together.
///
/// A plain overlay rather than a popover: a popover takes key window from the panel, and the
/// search field has to keep the keyboard while this is up — every one of these rows appears and
/// changes between two keystrokes. (The panel already paid for that lesson once: closing the
/// filter sheet handed first responder back to the search box and Space stopped opening previews.)
struct FilterSuggestionList: View {
    let suggestions: [FilterSuggestion]
    /// Which row Return would take. Moved with ↑ / ↓.
    let highlighted: Int
    let pick: (FilterSuggestion) -> Void

    /// Enough that one short name — "Text", "File" — still reads as a list rather than a stray tag.
    private static let minimumWidth: CGFloat = 168
    private static let cornerRadius: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                if index > 0 {
                    Divider()
                        .opacity(0.5)
                        // Starts where the labels do, so the rule separates the names rather than
                        // cutting the column of icons in half.
                        .padding(.leading, FilterSuggestionRow.labelInset)
                }
                FilterSuggestionRow(suggestion: suggestion,
                                    isHighlighted: index == highlighted) { pick(suggestion) }
            }
        }
        .frame(minWidth: Self.minimumWidth, alignment: .leading)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
    }
}

struct FilterSuggestionRow: View {
    /// Where a label starts: the row's leading padding, the icon, and the gap after it. The rule
    /// between two rows is inset by the same amount.
    static let labelInset: CGFloat = 40

    let suggestion: FilterSuggestion
    let isHighlighted: Bool
    let pick: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                icon
                label
                Spacer(minLength: 0)
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHighlighted ? 0.16 : (hovered ? 0.09 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    /// The typed part bright, the rest of the name dim — so the row reads as the query finishing
    /// itself rather than as an unrelated word appearing under the cursor.
    private var label: some View {
        let title = suggestion.title
        let start = title.index(title.startIndex, offsetBy: suggestion.matchOffset)
        let end = title.index(start, offsetBy: suggestion.matchLength)
        return (
            Text(String(title[title.startIndex..<start])).foregroundColor(.secondary)
            + Text(String(title[start..<end])).foregroundColor(.primary)
            + Text(String(title[end...])).foregroundColor(.secondary)
        )
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
    }

    @ViewBuilder
    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .frame(width: 22, height: 22)
            if let bundleID = suggestion.bundleID,
               let image = AppNameResolver.shared.icon(for: bundleID) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 15, height: 15)
            } else if let symbol = suggestion.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
            }
        }
    }
}

/// Draws the suggestion list under the search field, and is the only thing in the panel that
/// watches `PanelSuggestions`.
///
/// It sits at panel level rather than on the field because a SwiftUI view is not hit-tested
/// outside its parent's bounds: hung off the field, the list drew correctly and took no clicks —
/// `.onHover` never fired over it either. Here the container is the whole panel, so the rows are
/// where they look like they are.
struct SuggestionAnchor: View {
    @ObservedObject private var list = PanelSuggestions.shared

    /// Straight down from the field, just clear of it: the toolbar's 10pt padding, plus where the
    /// capsule's own bottom edge falls inside the 38pt bar, plus a 4pt gap. The toolbar is at the
    /// top of the panel whichever screen edge it is docked to, so this is the same on every side.
    private static let topInset: CGFloat = 10 + 34 + 4
    /// Past the capsule's own leading padding and the magnifier, so the list starts under the
    /// text rather than under the search icon.
    private static let leadingInset: CGFloat = 34
    /// The toolbar's own band and padding, repeated so the list lines up with the field above it.
    private static let bandWidth: CGFloat = 540
    private static let bandPadding: CGFloat = 14

    var body: some View {
        if !list.rows.isEmpty {
            HStack(spacing: 0) {
                FilterSuggestionList(suggestions: list.rows, highlighted: list.highlighted) { row in
                    PanelSuggestions.shared.take?(row)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, Self.leadingInset)
            .frame(maxWidth: Self.bandWidth)
            .padding(.horizontal, Self.bandPadding)
            .padding(.top, Self.topInset)
        }
    }
}
