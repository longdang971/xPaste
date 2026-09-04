import SwiftUI
import AppKit

/// A notice card that sits in the panel's card row, in place of — and the same shape as — a
/// clipboard card.
///
/// Every number here was measured off Paste's own "Run in Background" card, screenshotted on a
/// 2x display and read back in device pixels: the card is 400×464 pixels, i.e. **200×232pt**,
/// against the 232pt square of Paste's ordinary cards, with 11pt of padding on all four sides
/// (its title and body both wrap inside 178pt = 200 − 2×11). The icon sits at the top left with
/// the close button opposite it, the title and body follow, and the action pill is pinned to the
/// bottom edge — Paste's Enable button measures 69×30pt with its baseline 11pt off the card's
/// bottom.
///
/// The type was matched the same way, by inking the same strings on both panels and comparing
/// device pixels: the title inks 265px wide in Paste (15pt semibold), the body's second line
/// 216px (15pt regular, 19pt line height), and the symbol 43px square (a 22pt SF Symbol).
struct PanelNoticeCard: View {
    /// SF Symbol drawn at the top left.
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    let onAction: () -> Void
    let onDismiss: () -> Void

    /// Narrower than a clipboard card on purpose — this is Paste's own proportion.
    static let width: CGFloat = 200

    private static let padding: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .frame(height: 30, alignment: .top)

            // Fixed, not a flexible Spacer: only the gap above the action pill may stretch, or
            // the title floats away from the icon instead of sitting 6pt under it the way
            // Paste's does (icon at 11pt from the top, title at 47pt).
            Color.clear.frame(height: 6)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            Spacer(minLength: 8)

            // Pinned to the bottom padding — Paste's Enable button ends 11pt off the card's edge.
            Button(action: onAction) {
                Text(actionTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(Self.padding)
        .frame(width: Self.width, height: PanelLayout.cardBaseHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: ClipboardItemCard.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClipboardItemCard.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
    }
}
