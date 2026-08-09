import SwiftUI
import AppKit

/// Starts the AppKit dragging session for one card, and reports where it ended.
///
/// The session has to be AppKit's rather than SwiftUI's `.onDrag`: SwiftUI owns the session it creates
/// and tells us nothing about it, and this whole feature turns on knowing where the drag was
/// released, whether ⇧ was held there, and whether the target took the drop at all.
///
/// It decides nothing — `DragPaste` does. This only carries the decision out.
struct CardDragSource: NSViewRepresentable {
    /// Worked out when the drag actually starts rather than when the view is built: the selection may
    /// have moved in between.
    let plan: () -> DragPaste.Plan
    /// The plan, where it was released, what the target reported, whether ⇧ was held, whether the
    /// drag was cancelled.
    let onEnded: (DragPaste.Plan, NSPoint, NSDragOperation, Bool, Bool) -> Void

    func makeNSView(context: Context) -> CardDragSourceView {
        CardDragSourceView(plan: plan, onEnded: onEnded)
    }

    func updateNSView(_ nsView: CardDragSourceView, context: Context) {
        nsView.plan = plan
        nsView.onEnded = onEnded
    }
}

final class CardDragSourceView: NSView, NSDraggingSource {
    var plan: () -> DragPaste.Plan
    var onEnded: (DragPaste.Plan, NSPoint, NSDragOperation, Bool, Bool) -> Void
    private var observer: NSObjectProtocol?
    /// The plan the session in flight is carrying, so the end of the drag acts on what the start of
    /// it decided rather than on a selection that has moved since.
    private var draggingPlan: DragPaste.Plan?

    init(plan: @escaping () -> DragPaste.Plan,
         onEnded: @escaping (DragPaste.Plan, NSPoint, NSDragOperation, Bool, Bool) -> Void) {
        self.plan = plan
        self.onEnded = onEnded
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Claims nothing: the card underneath keeps its click, double-click and ⌘-click handling. The
    /// panel is what notices a drag, exactly as it notices those.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Flipped to match `PanelClickOverlay`, so a point converted down from the window lands where
    /// the card is drawn.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            return
        }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .dragOutOfPanel, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let origin = note.userInfo?["locationInWindow"] as? NSPoint,
                  let event = note.userInfo?["event"] as? NSEvent
            else { return }
            let local = self.convert(origin, from: nil)
            guard self.bounds.contains(local) else { return }
            self.beginDrag(with: event)
        }
    }

    private func beginDrag(with event: NSEvent) {
        let plan = self.plan()
        guard !plan.items.isEmpty else { return }

        let writers: [NSPasteboardWriting]
        switch plan.kind {
        case .deferredPaste:
            // One item, one private type, no public representation: nothing will accept this drop,
            // which is what leaves the release free to mean "paste here".
            let pbItem = NSPasteboardItem()
            pbItem.setString(plan.items.map { $0.id.uuidString }.joined(separator: ","),
                             forType: DragPaste.deferredType)
            writers = [pbItem]
        case .native:
            writers = plan.items.map(Self.nativeWriter(for:))
        }

        let image = Self.snapshot(of: superview, badge: plan.items.count)
        let items = writers.map { writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(bounds, contents: image)
            return item
        }
        draggingPlan = plan
        beginDraggingSession(with: items, event: event, source: self)
        NotificationCenter.default.post(name: .panelDragBegan, object: nil)
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let plan = draggingPlan else { return }
        draggingPlan = nil
        // A cancelled drag and a drop nobody accepted both arrive with an empty operation, so the
        // only thing left to tell them apart is the event that ended the session. The test is
        // positive — Escape and nothing else — because the two mistakes are not equal: reading
        // Escape as a release pastes something the user can undo, while reading a release as Escape
        // would make the whole feature look dead.
        let ending = NSApp.currentEvent
        let cancelled = ending?.type == .keyDown && ending?.keyCode == 53
        let shift = NSEvent.modifierFlags.contains(.shift)
        onEnded(plan, screenPoint, operation, shift, cancelled)
    }

    // MARK: - Payload

    /// What one item looks like on the dragging pasteboard when the target is meant to handle the drop
    /// itself: the real file where there is one, so Finder copies it and an upload zone receives it,
    /// and the picture or the link otherwise.
    static func nativeWriter(for item: ClipboardItem) -> NSPasteboardWriting {
        switch item.type {
        case .file, .folder:
            if let url = item.fileURLs?.first { return url as NSURL }
        case .image:
            if let url = ClipboardStore.shared.imageURL(for: item.id),
               FileManager.default.fileExists(atPath: url.path) {
                return url as NSURL
            }
            if let data = item.imageData, let image = NSImage(data: data) { return image }
        case .url:
            if let text = item.text, let url = URL(string: text) { return url as NSURL }
        case .text:
            break
        }
        return (item.text ?? item.displayText) as NSString
    }

    // MARK: - Drag image

    /// A picture of the card, so what is being dragged looks like what was pressed on.
    ///
    /// Rendered from the layer rather than with `cacheDisplay`: the card is SwiftUI's, drawn into a
    /// layer tree, and `cacheDisplay` comes back empty for those.
    static func snapshot(of view: NSView?, badge count: Int) -> NSImage? {
        guard let view, let layer = view.layer,
              view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        guard let ctx = CGContext(data: nil,
                                  width: Int(view.bounds.width * scale),
                                  height: Int(view.bounds.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let image = NSImage(cgImage: cg, size: view.bounds.size)
        guard count > 1 else { return image }
        return withBadge(count, on: image)
    }

    /// How many cards are travelling, drawn into the corner of the drag image.
    private static func withBadge(_ count: Int, on image: NSImage) -> NSImage {
        let badged = NSImage(size: image.size)
        badged.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        let text = "\(count)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        let diameter = max(textSize.width, textSize.height) + 12
        let circle = NSRect(x: image.size.width - diameter - 6,
                            y: image.size.height - diameter - 6,
                            width: diameter, height: diameter)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: circle).fill()
        text.draw(at: NSPoint(x: circle.midX - textSize.width / 2,
                              y: circle.midY - textSize.height / 2),
                  withAttributes: attrs)
        badged.unlockFocus()
        return badged
    }
}
