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

    /// The panel's layout scale, applied the same way `ClipboardItemCard` applies it: by
    /// multiplying the metrics, so the notice is laid out for the size it is drawn at. This card
    /// used to ignore the scale altogether and stayed 232pt tall inside a panel sized for a
    /// shorter one, which clipped its action button off the bottom edge on every laptop.
    @Environment(\.panelScale) private var panelScale
    private func s(_ value: CGFloat) -> CGFloat { value * panelScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: s(8)) {
                Image(systemName: symbol)
                    .font(.system(size: s(22), weight: .regular))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: s(13), weight: .regular))
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .frame(height: s(30), alignment: .top)

            // Fixed, not a flexible Spacer: only the gap above the action pill may stretch, or
            // the title floats away from the icon instead of sitting 6pt under it the way
            // Paste's does (icon at 11pt from the top, title at 47pt).
            Color.clear.frame(height: s(6))

            Text(title)
                .font(.system(size: s(15), weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(message)
                .font(.system(size: s(15)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, s(2))

            Spacer(minLength: s(8))

            // Pinned to the bottom padding — Paste's Enable button ends 11pt off the card's edge.
            Button(action: onAction) {
                Text(actionTitle)
                    .font(.system(size: s(14), weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, s(12))
                    .padding(.vertical, s(6))
                    .background(Capsule().fill(Color.primary.opacity(0.10)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(s(Self.padding))
        .frame(width: s(Self.width), height: s(PanelLayout.cardBaseHeight), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: s(ClipboardItemCard.cornerRadius), style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: s(ClipboardItemCard.cornerRadius), style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: s(10), x: 0, y: s(4))
    }
}
