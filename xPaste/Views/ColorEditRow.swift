import SwiftUI
import AppKit

/// What sits above the field while a colour is being edited, in place of the formatting toolbar.
///
/// Bold, a font family and a highlight mean nothing to `#1e90ff`; conversion between notations and
/// a contrast reading are what a colour actually needs. Everything here stays inside the popover —
/// `NSColorPanel` and SwiftUI's `ColorPicker` are both separate windows, and a separate window takes
/// key status, which the panel's glass follows and visibly dims behind. Measured when the delete
/// confirmation moved to a window of its own.
struct ColorEditRow: View {
    /// The text currently in the editor. The row is rebuilt as it changes.
    let text: String
    /// Applies a rewritten literal to the editor.
    let onRewrite: (String) -> Void

    /// Nil while the field holds something `ColorParser` no longer recognises — the user is
    /// allowed to type over a colour, and this row has to keep up rather than hold on to the last
    /// value it saw. The swatch goes empty and every conversion button disables itself; nothing
    /// here invents a colour that is not actually in the field any more.
    private var colour: NSColor? {
        ColorParser.parse(text).map { NSColor($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            swatch
            HStack(spacing: 4) {
                ForEach(ColorFormat.allCases, id: \.title) { format in
                    Button(format.title) {
                        if let colour { onRewrite(format.render(colour)) }
                    }
                    .controlSize(.small)
                    .disabled(colour == nil)
                    // Lands on the text view's own undo stack — see `EditSession.replaceAll(with:)`
                    // — so a conversion picked by mistake is one ⌘Z away, the same as any other edit.
                    .help("Convert to \(format.title)")
                    .accessibilityLabel("Convert to \(format.title)")
                }
            }
            Spacer()
            if let colour { contrast(for: colour) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(colour.map { Color(nsColor: $0) } ?? Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    // Every palette colour is a solid fill and white is one of them, so without a
                    // hairline the white swatch would be invisible against a light popover.
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            .frame(width: 44, height: 22)
            // A swatch with nothing behind it (the field no longer parses as a colour) has nothing
            // worth announcing, so it drops out of the accessibility tree entirely rather than
            // reading as an unlabelled shape.
            .accessibilityHidden(colour == nil)
            .accessibilityLabel("Colour swatch")
            .accessibilityValue(colour.map(ColorFormat.hex.render) ?? "")
    }

    /// The ratio alone says nothing without the threshold, so each reading carries its WCAG verdict
    /// for normal body text — that is the question someone picking a UI colour is actually asking.
    private func contrast(for colour: NSColor) -> some View {
        HStack(spacing: 8) {
            reading(colour, against: .white, label: "on white")
            reading(colour, against: .black, label: "on black")
        }
    }

    private func reading(_ colour: NSColor, against background: NSColor, label: String) -> some View {
        let ratio = RichTextRenderer.contrastRatio(colour, background)
        let text = "\(label) \(String(format: "%.1f", ratio)):1 \(Self.verdict(ratio))"
        return Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    /// The pure half of `reading(_:against:label:)`, pulled out for the same reason
    /// `RichTextToolbar.familyLabel(for:)` was: this view has no XCTest target reaching it, but the
    /// thresholds deciding what someone reads off this row are a plain number-in/string-out
    /// function, and those are worth testing directly.
    ///
    /// AA (4.5:1) and AAA (7:1) are WCAG 2.x's thresholds for normal-weight body text — not large
    /// text, which the spec lets off easier at 3:1 and 4.5:1. This row does not know the size the
    /// colour will end up used at, so it reports against the stricter body-text bar rather than
    /// silently assuming the more forgiving one.
    static func verdict(_ ratio: CGFloat) -> String {
        if ratio >= 7 { return "AAA" }
        if ratio >= 4.5 { return "AA" }
        return "✕"
    }
}
