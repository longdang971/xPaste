import AppKit
import AudioToolbox

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

    /// Main thread only. Registered once and kept for the life of the app.
    private static var ids: [Sound: SystemSoundID] = [:]

    /// Registers the sounds with the system sound server. Called at launch; cheap.
    ///
    /// Played through the system sound server rather than a player of xPaste's own. A player has to
    /// open its own stream to the output first, and on a USB output such as a Studio Display's
    /// speakers that took long enough to swallow the snap — whose whole body is its first 40 ms —
    /// so the first copy after launch was silent. Warming a player up at zero volume only moved the
    /// problem: a copy made right after launch landed inside the warm-up. The sound server keeps
    /// its output open all the time, which is what it is for: short interface sounds.
    static func prepare() {
        for sound in Sound.allCases { _ = soundID(for: sound) }
    }

    static func play(_ sound: Sound) {
        guard isEnabled(), let id = soundID(for: sound) else { return }
        AudioServicesPlaySystemSound(id)
    }

    static func soundID(for sound: Sound) -> SystemSoundID? {
        if let cached = ids[sound] { return cached }
        guard let url = url(for: sound) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == noErr else { return nil }
        ids[sound] = id
        return id
    }
}
