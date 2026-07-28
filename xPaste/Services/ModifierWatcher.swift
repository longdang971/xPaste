import AppKit
import Combine

/// Publishes the modifier keys currently held while the panel is open.
///
/// This deliberately does NOT live as `@State` on `ContentView`. Holding ⌘ fires a
/// `flagsChanged` on every press and release, and any state ContentView owns invalidates the
/// whole panel — measured at ~40ms of main-thread layout per press, in Release as well as
/// Debug. Keeping it in a separate object means only the little badge views that observe it
/// are rebuilt.
final class ModifierWatcher: ObservableObject {
    static let shared = ModifierWatcher()

    @Published private(set) var flags: NSEvent.ModifierFlags = []

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let centre = NotificationCenter.default
        observers.append(centre.addObserver(forName: .panelDidOpen, object: nil, queue: .main) { [weak self] _ in
            self?.start()
        })
        observers.append(centre.addObserver(forName: .panelWillHide, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        })
    }

    private func start() {
        // The activation hotkey is ⇧⌘V, so the modifiers are usually still down and no
        // flagsChanged has fired yet — seed from the current keyboard state.
        let held = NSEvent.modifierFlags.intersection(Self.tracked)
        if held != flags { flags = held }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let relevant = event.modifierFlags.intersection(Self.tracked)
            if relevant != self.flags { self.flags = relevant }
            return event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        // No flagsChanged arrives once the panel stops being key, so the badges would
        // otherwise still be showing the next time it opens.
        if !flags.isEmpty { flags = [] }
    }

    private static let tracked: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
}
