import SwiftUI
import AppKit
import QuickLookThumbnailing

/// What the notch is showing. Owned by `NotchController`, drawn by `NotchView`.
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        /// Tucked behind the camera housing, invisible.
        case idle
        /// A copy (or a drop) was just saved.
        case toast(NotchToast)
        /// The most recent items, opened by resting the pointer on the housing.
        case shelf
        /// Something is being dragged over the housing.
        case drop
    }

    @Published var mode: Mode = .idle
    @Published var shelfItems: [ClipboardItem] = []
    /// What a drag can be dropped as, left to right. Decided once, as the drag comes in.
    @Published var dropZones: [NotchDropZone] = NotchDropZone.allCases
    /// The zone under the drag, which is what a drop now would do.
    @Published var dropTarget: NotchDropZone = .save
    var notchSize = CGSize(width: 200, height: 32)

    /// Pastes an item from the shelf. Set by the controller.
    var onPick: (ClipboardItem) -> Void = { _ in }
    /// Opens the full panel. Set by the controller.
    var onOpenPanel: () -> Void = {}

    /// The banner's buttons, each acting on the item the banner is about. Set by the controller.
    var onTogglePin: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }
    var onCopyText: (UUID) -> Void = { _ in }

    /// Where each shelf tile is drawn, in the hosting view's top-left coordinates, so a press can
    /// be traced back to the tile it landed on when it turns into a drag. Not published: nothing
    /// on screen depends on it.
    var tileFrames: [UUID: CGRect] = [:]
    /// Where each drop zone is drawn, in the same coordinates.
    var dropZoneFrames: [NotchDropZone: CGRect] = [:]
}

/// What a drop on the notch does, one per zone of the drop target.
enum NotchDropZone: CaseIterable, Hashable {
    case save
    case pin
    /// Reads the text out of a picture and copies it. Offered only for a drag carrying pictures.
    case text

    var title: String {
        switch self {
        case .save: return "Save"
        case .pin: return "Save & Pin"
        case .text: return "Copy Text"
        }
    }

    var subtitle: String {
        switch self {
        case .save: return "Add to history"
        case .pin: return "Keep it on top"
        case .text: return "Read the image"
        }
    }

    var symbol: String {
        switch self {
        case .save: return "tray.and.arrow.down.fill"
        case .pin: return "pin.fill"
        case .text: return "text.viewfinder"
        }
    }

    /// Each zone's own colour, so the three read apart at a glance rather than by their words.
    var accent: Color {
        switch self {
        case .save: return Color(nsColor: .systemBlue)
        case .pin: return Color(nsColor: .systemOrange)
        case .text: return Color(nsColor: .systemPurple)
        }
    }

    /// The zones a drag gets: reading text only when there is a picture to read it from.
    static func zones(carryingImages: Bool) -> [NotchDropZone] {
        carryingImages ? [.save, .pin, .text] : [.save, .pin]
    }

    /// The zone a drop at `x` lands in: the nearest one, so the gaps between them and the band
    /// around the camera are not places where a drop does nothing.
    static func nearest(to x: CGFloat, in frames: [NotchDropZone: CGRect]) -> NotchDropZone? {
        frames.min { abs($0.value.midX - x) < abs($1.value.midX - x) }?.key
    }
}

/// The contents of one "saved" banner.
struct NotchToast: Equatable {
    let id = UUID()
    let title: String
    let text: String
    var image: NSImage? = nil
    var color: Color? = nil
    var symbol: String = "doc.on.clipboard"
    /// The item the banner is about. Only a banner with one gets the buttons; a notice ("Removed",
    /// "press ⌘V") has nothing for them to act on.
    var itemID: UUID? = nil
    var isPinned = false
    var isImage = false
    /// Something is still being worked on: a spinner where the tick would be.
    var busy = false

    static func == (a: NotchToast, b: NotchToast) -> Bool { a.id == b.id }

    /// The banner for an item that was just saved. `title` says how it got there; `stored` is
    /// the item the history keeps for it, when that is a different one (see `ClipboardStore.add`).
    static func make(for item: ClipboardItem, storedAs stored: ClipboardItem? = nil,
                     title: String) -> NotchToast {
        var toast = NotchToast(title: title, text: NotchText.summary(of: item))
        toast.itemID = (stored ?? item).id
        toast.isPinned = (stored ?? item).isPinned
        toast.isImage = item.type == .image
        switch item.type {
        case .image:
            toast.image = item.imageData.flatMap(NSImage.init(data:))
            toast.symbol = "photo"
        case .file, .folder:
            if let url = item.fileURLs?.first {
                toast.image = NSWorkspace.shared.icon(forFile: url.path)
            }
            toast.symbol = item.type == .folder ? "folder" : "doc"
        case .color:
            toast.color = item.text.flatMap(ColorParser.parse)
            toast.symbol = "paintpalette"
        case .url:
            toast.symbol = "link"
        case .text:
            toast.symbol = "text.alignleft"
        }
        if toast.image == nil, toast.color == nil, let bid = item.sourceAppBundleID {
            // The shelf's 64pt copy: `AppNameResolver` keeps an 18pt one for menus, and drawn at
            // 34pt here it came out soft.
            toast.image = ShelfTile.icon(for: bid)
        }
        return toast
    }
}

/// Which items the shelf shows.
enum NotchShelfItems {
    /// The most recently copied, newest first.
    ///
    /// Sorted here rather than taken from the front of the history: the history is loaded pinned
    /// first, so after a relaunch the front of it is old pinned snippets, not what was just copied.
    static func recent(_ items: [ClipboardItem], count: Int = NotchLayout.shelfCount) -> [ClipboardItem] {
        Array(items.sorted { $0.timestamp > $1.timestamp }.prefix(count))
    }
}

/// One-line descriptions of an item, for a banner or a shelf card.
enum NotchText {
    static func summary(of item: ClipboardItem) -> String {
        if let label = item.label, !label.isEmpty { return label }
        switch item.type {
        case .text, .color:
            return firstLine(of: item.text ?? "")
        case .url:
            let link = linkParts(of: item)
            return link.host + link.path
        case .image:
            return "Image"
        case .file, .folder:
            let names = item.fileURLs?.map(\.lastPathComponent) ?? []
            guard let first = names.first else { return item.displayText }
            return names.count > 1 ? "\(first) +\(names.count - 1)" : first
        }
    }

    /// A link as its host (without `www.`) and the rest of its path.
    static func linkParts(of item: ClipboardItem) -> (host: String, path: String) {
        let raw = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let host = url.host else { return (raw, "") }
        let path = url.path == "/" ? "" : url.path
        return (host.replacingOccurrences(of: "www.", with: "", options: .anchored), path)
    }

    /// How long ago, in the fewest characters that still read: "now", "5m", "3h", "2d".
    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    /// How a piece of text is set on a shelf tile.
    enum TextStyle: Equatable {
        /// A few words: set large, the way a sticky note would be.
        case short
        /// Looks like source code: monospaced, smaller, more lines.
        case code
        case prose

        var font: Font {
            switch self {
            case .short: return .system(size: 15, weight: .semibold)
            case .code: return .system(size: 10.5, weight: .regular, design: .monospaced)
            case .prose: return .system(size: 12, weight: .medium)
            }
        }

        var lineLimit: Int {
            switch self {
            case .short: return 3
            case .code: return 6
            case .prose: return 5
            }
        }
    }

    static func textStyle(of text: String) -> TextStyle {
        let lines = text.split(whereSeparator: \.isNewline)
        if lines.count >= 2 {
            let marks = ["{", "}", ";", "=>", "->", "()", "</", "def ", "func ", "const ", "let ", "import "]
            let hits = lines.filter { line in marks.contains { line.contains($0) } }.count
            let indented = lines.contains { $0.hasPrefix("  ") || $0.hasPrefix("\t") }
            if hits * 2 >= lines.count || (indented && hits > 0) { return .code }
        }
        if lines.count == 1, text.count <= 32 { return .short }
        return .prose
    }

    /// The first line that has anything on it, with its surrounding whitespace dropped.
    static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// Sizes of each state, all derived from the housing so they read as growing out of it.
enum NotchLayout {
    /// How far the top corners flare outward into the menu bar.
    static let flare: CGFloat = 10
    static let shelfCardSize = CGSize(width: 112, height: 112)
    static let shelfCardSpacing: CGFloat = 10
    static let shelfCount = 6
    static let shelfPadding: CGFloat = 12
    /// Room either side of the housing for the shelf's header.
    static let shelfWing: CGFloat = 120
    /// Corner radius of a shelf tile. The shelf's own corner is this plus the padding around the
    /// tiles, so the two curves are concentric.
    static let shelfTileRadius: CGFloat = 16
    /// Above the tiles, so a hovered tile's ring and lift are not cut off by the header band.
    static let shelfTopGap: CGFloat = 8
    static let shelfBottomGap: CGFloat = 14
    /// A drop zone is as wide as a shelf tile, so the two states read as one family.
    static let dropZoneWidth: CGFloat = 112
    static let dropZoneSpacing: CGFloat = 8
    static let dropPadding: CGFloat = 14
    static let dropZoneHeight: CGFloat = 104
    /// Same rounding as a shelf tile, and the target's corner concentric with it.
    static let dropZoneRadius: CGFloat = shelfTileRadius

    static func size(of mode: NotchModel.Mode, notch: CGSize, shelfItems: Int = shelfCount,
                     dropZones: Int = 2) -> CGSize {
        switch mode {
        case .idle:
            // A shade smaller than the housing, so nothing of it shows past the housing's edge.
            // Still drawn, though: a window with nothing opaque in it is not a drop target.
            return CGSize(width: max(notch.width - 8, 0), height: max(notch.height - 2, 0))
        case .toast:
            return even(CGSize(width: max(notch.width + 2 * flare + 160, 360),
                               height: notch.height + 58))
        case .drop:
            let count = CGFloat(max(dropZones, 1))
            let zones = count * dropZoneWidth + (count - 1) * dropZoneSpacing + 2 * dropPadding
            return even(CGSize(width: max(zones + 2 * flare, notch.width + 2 * flare + 140, 340),
                               height: notch.height + shelfTopGap + dropZoneHeight + dropPadding))
        case .shelf:
            // As wide as the cards there are, so two items do not sit in a band built for six.
            let count = CGFloat(min(max(shelfItems, 1), shelfCount))
            let cards = count * shelfCardSize.width + (count - 1) * shelfCardSpacing
            let header = notch.width + 2 * shelfWing
            return even(CGSize(width: max(cards + 2 * shelfPadding, header) + 2 * flare,
                               height: notch.height + shelfTopGap + shelfCardSize.height + shelfBottomGap))
        }
    }

    /// Whole, even points: the window is centred on the housing, and an odd width would put the
    /// shape half a point off it.
    private static func even(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width / 2).rounded(.up) * 2, height: size.height.rounded(.up))
    }

    static func bottomRadius(of mode: NotchModel.Mode) -> CGFloat {
        switch mode {
        case .idle: return 8
        case .shelf: return shelfTileRadius + shelfPadding
        case .drop: return dropZoneRadius + dropPadding
        case .toast: return 20
        }
    }

    static func flare(of mode: NotchModel.Mode) -> CGFloat {
        mode == .idle ? 0 : flare
    }
}

extension NotchModel {
    func size(of mode: Mode) -> CGSize {
        NotchLayout.size(of: mode, notch: notchSize, shelfItems: shelfItems.count,
                         dropZones: dropZones.count)
    }
}

/// The housing grown downward: straight sides, rounded bottom corners, and top corners that curve
/// outward into the menu bar the way the housing's own do.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, bottomRadius) }
        set { flare = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.width / 4)
        let r = min(bottomRadius, (rect.width - 2 * f) / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f),
                       control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY),
                       control: CGPoint(x: rect.minX + f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r),
                       control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var model: NotchModel

    static let animation = Animation.spring(response: 0.4, dampingFraction: 0.8)

    /// The contents wait for the shape to open before fading in, and leave quickly before it
    /// closes, so text is never seen squeezed by the edges sweeping past it.
    private static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
            .animation(.easeOut(duration: 0.2).delay(0.1)),
        removal: .opacity.animation(.easeIn(duration: 0.08))
    )

    var body: some View {
        let size = model.size(of: model.mode)
        ZStack(alignment: .top) {
            NotchShape(flare: NotchLayout.flare(of: model.mode),
                       bottomRadius: NotchLayout.bottomRadius(of: model.mode))
                .fill(Color.black)
            content
                .padding(.horizontal, NotchLayout.flare(of: model.mode))
                .transition(Self.contentTransition)
        }
        // Centred on the housing and pinned to the top, so the width grows out to both sides at
        // once and the height grows downward.
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(flare: NotchLayout.flare(of: model.mode),
                              bottomRadius: NotchLayout.bottomRadius(of: model.mode)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .animation(Self.animation, value: model.mode)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .idle:
            EmptyView()
        case .toast(let toast):
            ToastRow(toast: toast, model: model)
                .padding(.top, model.notchSize.height)
                .id(toast.id)
        case .drop:
            DropZones(model: model)
                .padding(.top, model.notchSize.height)
        case .shelf:
            Shelf(model: model)
        }
    }
}

private struct ToastRow: View {
    let toast: NotchToast
    let model: NotchModel
    /// Kept here rather than read back from the store: the banner is about one item, for a second
    /// or two, and observing the whole history to redraw one pin would redraw it on every copy.
    @State private var pinned: Bool
    @State private var reading = false

    init(toast: NotchToast, model: NotchModel) {
        self.toast = toast
        self.model = model
        _pinned = State(initialValue: toast.isPinned)
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(toast.text.isEmpty ? " " : toast.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if let id = toast.itemID {
                HStack(spacing: 2) {
                    BannerButton(symbol: pinned ? "pin.fill" : "pin",
                                 help: pinned ? "Unpin" : "Pin", active: pinned) {
                        pinned.toggle()
                        model.onTogglePin(id)
                    }
                    if toast.isImage {
                        BannerButton(symbol: "text.viewfinder", help: "Copy text in image",
                                     busy: reading) {
                            reading = true
                            model.onCopyText(id)
                        }
                    }
                    BannerButton(symbol: "trash", help: "Remove from history") {
                        model.onRemove(id)
                    }
                }
            } else if toast.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder private var thumbnail: some View {
        if let color = toast.color {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        } else if let image = toast.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                .overlay(Image(systemName: toast.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary))
        }
    }
}

/// One of the banner's round buttons, in the manner of `ShowAllButton`: faint until the pointer
/// is on it.
private struct BannerButton: View {
    let symbol: String
    let help: String
    var active = false
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(Color.white.opacity(hovering || active ? 0.95 : 0.6))
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(busy)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The drop target, split into what a drop can do: tiles in the shelf's manner, the one under
/// the drag lifted and ringed the way a hovered shelf tile is, the others dimmed behind it.
private struct DropZones: View {
    @ObservedObject var model: NotchModel
    /// Drives the staggered entrance, as the shelf's tiles have.
    @State private var appeared = false

    var body: some View {
        HStack(spacing: NotchLayout.dropZoneSpacing) {
            ForEach(Array(model.dropZones.enumerated()), id: \.element) { index, zone in
                DropZoneCell(zone: zone, targeted: model.dropTarget == zone)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: DropZoneFrames.self,
                                               value: [zone: geo.frame(in: .global)])
                    })
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -10)
                    .scaleEffect(appeared ? 1 : 0.9, anchor: .top)
                    .animation(.spring(response: 0.42, dampingFraction: 0.78)
                        .delay(0.07 + Double(index) * 0.035), value: appeared)
            }
        }
        .frame(height: NotchLayout.dropZoneHeight)
        .onPreferenceChange(DropZoneFrames.self) { model.dropZoneFrames = $0 }
        .padding(.horizontal, NotchLayout.dropPadding)
        .padding(.top, NotchLayout.shelfTopGap)
        .onAppear { appeared = true }
    }
}

private struct DropZoneCell: View {
    let zone: NotchDropZone
    let targeted: Bool

    private static let radius = NotchLayout.dropZoneRadius

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        VStack(spacing: 0) {
            badge
            Spacer(minLength: 8)
            Text(zone.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(1)
            Text(zone.subtitle)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(1)
                .padding(.top, 2)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color(white: 0.105)
                // The zone's colour rising from the bottom, brighter under the drag.
                RadialGradient(colors: [zone.accent.opacity(targeted ? 0.6 : 0.22), zone.accent.opacity(0)],
                               center: .bottom, startRadius: 0, endRadius: 110)
            }
        )
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(targeted ? 0.16 : 0.07), lineWidth: 0.5))
        // The macOS selection ring, as on a hovered shelf tile.
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
                .strokeBorder(Color.white.opacity(targeted ? 0.9 : 0), lineWidth: 2)
                .padding(-3.5)
        )
        .opacity(targeted ? 1 : 0.62)
        .scaleEffect(targeted ? 1.04 : 1)
        .shadow(color: .black.opacity(targeted ? 0.5 : 0), radius: 8, y: 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: targeted)
    }

    /// The symbol on a disc of the zone's colour, which swells when the drag arrives over it.
    private var badge: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [zone.accent.opacity(0.95), zone.accent.opacity(0.65)],
                                     startPoint: .top, endPoint: .bottom))
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
            Image(systemName: zone.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
        }
        .frame(width: 40, height: 40)
        .shadow(color: zone.accent.opacity(targeted ? 0.7 : 0), radius: 10)
        .scaleEffect(targeted ? 1.14 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: targeted)
    }
}

private struct DropZoneFrames: PreferenceKey {
    static var defaultValue: [NotchDropZone: CGRect] = [:]
    static func reduce(value: inout [NotchDropZone: CGRect], nextValue: () -> [NotchDropZone: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Shelf

private struct Shelf: View {
    @ObservedObject var model: NotchModel
    /// Drives the tiles' staggered entrance. Starts false on every open: the shelf is rebuilt
    /// each time the notch leaves idle.
    @State private var appeared = false

    private var hotkey: String {
        UserDefaults.standard.string(forKey: HotkeyDefaults.displayKey) ?? HotkeyDefaults.display
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: model.notchSize.height)
            if model.shelfItems.isEmpty {
                empty
            } else {
                HStack(spacing: NotchLayout.shelfCardSpacing) {
                    ForEach(Array(model.shelfItems.enumerated()), id: \.element.id) { index, item in
                        ShelfTile(item: item) { model.onPick(item) }
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: ShelfTileFrames.self,
                                                       value: [item.id: geo.frame(in: .global)])
                            })
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : -10)
                            .scaleEffect(appeared ? 1 : 0.9, anchor: .top)
                            .animation(.spring(response: 0.42, dampingFraction: 0.78)
                                .delay(0.07 + Double(index) * 0.035), value: appeared)
                    }
                }
                .padding(.top, NotchLayout.shelfTopGap)
                .onPreferenceChange(ShelfTileFrames.self) { model.tileFrames = $0 }
                Spacer(minLength: 0)
            }
        }
        .onAppear { appeared = true }
    }

    /// The band either side of the camera: a name in the left wing, the way to the full panel in
    /// the right. Nothing in the middle — that part of the band is under the housing.
    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.62, blue: 1),
                                                  Color(red: 0.67, green: 0.45, blue: 1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 7, height: 7)
                Text("Clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
            Spacer(minLength: model.notchSize.width + 24)
            ShowAllButton(hotkey: hotkey, action: model.onOpenPanel)
        }
        .padding(.horizontal, NotchLayout.shelfPadding + 6)
    }

    /// The panel's own words and manner — see `ContentView.emptyState`: one line, no icon, in a
    /// faint label colour. Smaller than the panel's 26pt to suit a shelf a sixth of its size.
    private var empty: some View {
        Text("History is empty")
            .font(.system(size: 18))
            .foregroundStyle(Color.white.opacity(0.32))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShelfTileFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ShowAllButton: View {
    let hotkey: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Show all")
                    .font(.system(size: 11, weight: .medium))
                // No chip at all when the shortcut has been cleared, rather than an empty key.
                if !hotkey.isEmpty {
                    Text(hotkey)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.12)))
                }
            }
            .foregroundStyle(Color.white.opacity(hovering ? 0.95 : 0.6))
            .padding(.leading, 9)
            .padding(.trailing, hotkey.isEmpty ? 9 : 4)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Shrinks a touch while pressed, so a click on a tile is felt before the shelf closes.
private struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// One item on the shelf: its content first and filling the tile, with where it came from and
/// when along the bottom.
private struct ShelfTile: View {
    let item: ClipboardItem
    let pick: () -> Void

    @State private var hovering = false
    @State private var accent: Color
    @State private var picture: NSImage?
    @State private var link: LinkPreviewData?
    @State private var favicon: NSImage?
    /// Quick Look's rendering of each file, in `fileURLs` order; nil where there is none.
    @State private var thumbnails: [NSImage?] = []
    @AppStorage("linkPreviewEnabled") private var linkPreviewEnabled = true

    private static let radius = NotchLayout.shelfTileRadius
    private static let size = NotchLayout.shelfCardSize
    private static let tileBase = Color(white: 0.105)

    init(item: ClipboardItem, pick: @escaping () -> Void) {
        self.item = item
        self.pick = pick
        _accent = State(initialValue: ClipboardItemCard.cachedAccent(for: item))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    }

    var body: some View {
        Button(action: pick) {
            ZStack(alignment: .bottomLeading) {
                background
                content
                // A swatch is nothing but its colour and its code, as on the panel, which gives a
                // colour card no footer either. Links carry their own, naming the site, which
                // says more about a link than when it was copied.
                if item.type != .color, item.type != .url {
                    meta
                        .padding(.horizontal, isPhoto ? 6 : 9)
                        .padding(.bottom, isPhoto ? 6 : 8)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipShape(shape)
            // A hairline inside the edge, so a tile keeps its outline against the black even when
            // its content is dark too.
            .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
            // The selection ring macOS draws around a focused item: a gap, then a white line.
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius + 3, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.9 : 0), lineWidth: 2)
                    .padding(-3.5)
            )
            .scaleEffect(hovering ? 1.035 : 1)
            .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 8, y: 4)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
            .contentShape(shape)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(NotchText.summary(of: item))
        .task(id: item.id) { await load() }
    }

    /// A picture covers the tile edge to edge, and the meta row sits on it in a chip of its own:
    /// a scrim alone left "now" white-on-white over a white screenshot.
    private var isPhoto: Bool { item.type == .image && picture != nil }

    // MARK: Layers

    @ViewBuilder private var background: some View {
        switch item.type {
        case .color:
            item.text.flatMap(ColorParser.parse) ?? Self.tileBase
        case .image:
            if let picture {
                Color.clear.overlay(Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill))
            } else {
                Self.tileBase
            }
        default:
            // Where the colour comes in: the source app's own colour, glowing from the top corner
            // of an otherwise near-black tile.
            ZStack {
                Self.tileBase
                RadialGradient(colors: [accent.opacity(0.55), accent.opacity(0)],
                               center: .topLeading, startRadius: 0, endRadius: Self.size.width * 1.05)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch item.type {
        case .image:
            if picture == nil { glyph("photo") }
        case .color:
            // Centred, as on the panel's colour card — see `ClipboardItemCard.colorPreview`.
            Text(ColorParser.displayLiteral(item.text ?? ""))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(swatchInk)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file, .folder:
            files
        case .url:
            // The panel's three link cards, decided the same way — see `ClipboardItemCard`: a link
            // to a file shows its type's icon; a picture that is really a logo (small, or square)
            // sits at icon size instead of being blown up across the tile; anything else fills it.
            if let link, link.isDownload {
                linkPlate {
                    Image(nsImage: ClipboardItemCard.downloadIcon(fileName: link.title, mimeType: link.mimeType))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 46, height: 46)
                }
            } else if let image = link?.image, !ClipboardItemCard.isLogoSized(image) {
                linkBanner(image)
            } else if let logo = link?.image ?? favicon {
                linkPlate {
                    Image(nsImage: logo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                }
            } else {
                linkPlate {
                    Image(systemName: ClipboardItemCard.placeholderSymbolName)
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            }
        case .text:
            text
        }
    }

    // MARK: Text

    private var trimmedText: String {
        (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder private var text: some View {
        let body = trimmedText
        let style = NotchText.textStyle(of: body)
        Text(body)
            .font(style.font)
            .foregroundStyle(Color.white.opacity(0.95))
            .lineSpacing(style == .code ? 1 : 1.5)
            .lineLimit(style.lineLimit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 26)
            // Long text fades out above the meta row instead of stopping at a hard line.
            .mask(LinearGradient(stops: [.init(color: .black, location: 0.7),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }

    // MARK: Links

    private var linkTitle: String? {
        link?.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// A link's one line of footer: the site's icon and name. Not the app it was copied from, as
    /// the panel's card has: at this size a second icon crowded the host out, and a link almost
    /// always comes from a browser, which says nothing.
    private var linkFooter: some View {
        let parts = NotchText.linkParts(of: item)
        return HStack(spacing: 5) {
            Group {
                if let favicon {
                    Image(nsImage: favicon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").resizable().foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .frame(width: 12, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(parts.host)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 13)
    }

    /// A page's picture fills the tile, and the title and footer sit on it over a shade that
    /// rises from the bottom edge and fades out, so there is no band and no hard line.
    private func linkBanner(_ image: NSImage) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay(Image(nsImage: image).resizable().aspectRatio(contentMode: .fill))
                .clipped()
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0.3),
                                   .init(color: .black.opacity(0.55), location: 0.62),
                                   .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(linkTitle ?? NotchText.linkParts(of: item).path)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                linkFooter
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
        }
    }

    /// A link with no picture to fill the tile, as the panel draws one — see
    /// `ClipboardItemCard.noImagePlaceholder`: something in the middle (the site's logo, a file
    /// type's icon, or Safari's compass), and under it the same title and footer as a link with a
    /// picture.
    private func linkPlate<Center: View>(@ViewBuilder _ center: () -> Center) -> some View {
        let parts = NotchText.linkParts(of: item)
        return ZStack(alignment: .bottomLeading) {
            center()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(linkTitle ?? (parts.path.isEmpty ? parts.host : parts.path))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                linkFooter
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
        }
    }

    // MARK: Files

    private var urls: [URL] { item.fileURLs ?? [] }

    private func preview(at index: Int) -> NSImage {
        if index < thumbnails.count, let thumb = thumbnails[index] { return thumb }
        return NSWorkspace.shared.icon(forFile: urls[index].path)
    }

    /// One file shows itself — Quick Look's picture of it where there is one, its icon where not.
    /// Several fan out like a hand of cards, with a count rather than the first one's name.
    @ViewBuilder private var files: some View {
        VStack(spacing: 6) {
            if urls.count > 1 {
                ZStack {
                    ForEach(Array(urls.prefix(3).enumerated().reversed()), id: \.offset) { index, _ in
                        let spread = Double(index) - Double(min(urls.count, 3) - 1) / 2
                        Image(nsImage: preview(at: index))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                            .shadow(color: .black.opacity(0.4), radius: 3, y: 2)
                            .rotationEffect(.degrees(spread * 12), anchor: .bottom)
                            .offset(x: spread * 14)
                    }
                }
                .frame(height: 48)
            } else if !urls.isEmpty {
                let isThumb = !thumbnails.isEmpty && thumbnails[0] != nil
                Image(nsImage: preview(at: 0))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: isThumb ? 64 : 46, maxHeight: isThumb ? 52 : 46)
                    .clipShape(RoundedRectangle(cornerRadius: isThumb ? 4 : 0, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                    .frame(height: 52)
            }
            Text(filesCaption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 18)
    }

    private var filesCaption: String {
        guard urls.count > 1 else { return urls.first?.lastPathComponent ?? NotchText.summary(of: item) }
        let noun = item.type == .folder ? "folders" : "files"
        return "\(urls.count) \(noun)"
    }

    // MARK: Meta

    /// Where it came from and when.
    private var meta: some View {
        HStack(spacing: 5) {
            if let bid = item.sourceAppBundleID, let icon = ShelfTile.icon(for: bid) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
            }
            Text(NotchText.age(of: item.timestamp))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(isPhoto ? 0.9 : 0.7))
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            if let label = item.label, !label.isEmpty {
                Image(systemName: "tag.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .frame(height: 15)
        .padding(.leading, isPhoto ? 3 : 0)
        .padding(.trailing, isPhoto ? 7 : 0)
        .padding(.vertical, isPhoto ? 3 : 0)
        .background {
            if isPhoto { Capsule().fill(Color.black.opacity(0.55)) }
        }
    }

    /// The panel's own swatch tint, so the hex code reads the same on both — see
    /// `ClipboardItemCard.onSwatchTint`.
    private var swatchInk: Color {
        guard let swatch = item.text.flatMap(ColorParser.parse) else { return .white }
        return ClipboardItemCard.onSwatchTint(NSColor(swatch))
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 22, weight: .light))
            .foregroundStyle(Color.white.opacity(0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loading

    private func load() async {
        accent = await ClipboardItemCard.accent(for: item)
        switch item.type {
        case .image:
            picture = await ClipboardStore.shared.loadImage(for: item.id)
        case .file, .folder:
            var found: [NSImage?] = []
            for url in urls.prefix(3) { found.append(await FileThumbnail.image(for: url)) }
            thumbnails = found
        case .url:
            // Usually already cached: the panel's card asked for the same page when the link was
            // copied. Off when the user turned link previews off, as the panel's are.
            guard linkPreviewEnabled,
                  let url = URL(string: trimmedText) else { return }
            async let meta = LinkPreviewService.shared.fetchMetadata(url)
            async let icon = LinkPreviewService.shared.fetchFavicon(for: url)
            async let image = LinkPreviewService.shared.fetchImage(for: url)
            let (m, f) = await (meta, icon)
            link = m
            favicon = f
            if let img = await image, let m {
                link = LinkPreviewData(title: m.title, imageURL: m.imageURL, image: img, domain: m.domain,
                                       isDirectImage: m.isDirectImage, isDownload: m.isDownload,
                                       mimeType: m.mimeType)
            }
        default:
            break
        }
    }

    private static var iconCache: [String: NSImage] = [:]

    /// The source app's icon at 64pt, so it stays crisp at the 15pt it is drawn — and the copy is
    /// shared by every tile from the same app.
    static func icon(for bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 64, height: 64)
        iconCache[bundleID] = icon
        return icon
    }
}

/// Quick Look's picture of a file's contents — the first page of a PDF, the photo itself — for
/// the shelf. Nil for anything Quick Look can only draw an icon for, so the caller shows the icon
/// at its proper size instead of an icon squeezed into a thumbnail's frame.
enum FileThumbnail {
    private static let cache = NSCache<NSURL, NSImage>()

    static func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                   scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        cache.setObject(rep.nsImage, forKey: url as NSURL)
        return rep.nsImage
    }
}
