import AppKit

/// The short cue xPaste plays when it captures a copy: a synthesised paper snap shipped in
/// `Resources/Sounds`, soft enough not to sound like a system alert. Pasting is silent — a paste
/// sound was tried and dropped.
enum SoundEffects {
    enum Sound: CaseIterable {
        case copy

        fileprivate var resourceName: String {
            switch self {
            case .copy: return "xpaste-copy"
            }
        }
    }

    /// Settings › General › Play sounds. Absent means on: a fresh install plays them.
    static let defaultsKey = "playSounds"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func url(for sound: Sound) -> URL? {
        Bundle.main.url(forResource: sound.resourceName, withExtension: "caf")
    }

    /// Main thread only. Loaded once and kept, so the first copy after launch is not the one that
    /// pays for reading the file.
    private static var loaded: [Sound: NSSound] = [:]

    static func play(_ sound: Sound) {
        guard isEnabled() else { return }
        let player: NSSound
        if let cached = loaded[sound] {
            player = cached
        } else {
            guard let url = url(for: sound),
                  let fresh = NSSound(contentsOf: url, byReference: true) else { return }
            loaded[sound] = fresh
            player = fresh
        }
        // `play()` on an NSSound that is still sounding does nothing and returns false, so two
        // quick copies would only ever make one noise. Rewind it instead.
        player.stop()
        player.play()
    }
}
