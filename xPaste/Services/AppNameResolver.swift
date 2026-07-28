import AppKit

/// Bundle ID → human name ("com.google.Chrome" → "Google Chrome"), cached.
///
/// Resolution goes through LaunchServices, which is far too slow to call while filtering the
/// history on every keystroke; failures are remembered too, so an item copied from an app that
/// has since been uninstalled doesn't re-query forever.
final class AppNameResolver {
    static let shared = AppNameResolver()

    private var cache: [String: String] = [:]
    private var unresolved: Set<String> = []
    private let lock = NSLock()

    private init() {}

    /// The app's icon at menu size, cached alongside the name.
    func icon(for bundleID: String) -> NSImage? {
        lock.lock()
        if let cached = icons[bundleID] { lock.unlock(); return cached }
        lock.unlock()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        guard let copy = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 18, height: 18)
        lock.lock(); icons[bundleID] = copy; lock.unlock()
        return copy
    }

    private var icons: [String: NSImage] = [:]

    func name(for bundleID: String) -> String? {
        lock.lock()
        if let cached = cache[bundleID] { lock.unlock(); return cached }
        if unresolved.contains(bundleID) { lock.unlock(); return nil }
        lock.unlock()

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            lock.lock(); unresolved.insert(bundleID); lock.unlock()
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        lock.lock(); cache[bundleID] = name; lock.unlock()
        return name
    }
}
