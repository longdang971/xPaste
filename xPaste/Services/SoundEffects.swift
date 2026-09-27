import AppKit
import AVFoundation

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

    /// Main thread only. One player per sound, kept for the life of the app.
    private static var players: [Sound: AVAudioPlayer] = [:]

    /// Loads the sounds and takes hold of the audio output ahead of time. Called at launch.
    ///
    /// Without it the first copy after launch made no sound at all: the player was only built on
    /// that copy, and the output was still starting up while the snap — whose whole body is its
    /// first 40 ms — went by. `prepareToPlay` fills the buffers and acquires the hardware now.
    static func prepare() {
        guard isEnabled() else { return }
        for sound in Sound.allCases { _ = player(for: sound) }
    }

    static func play(_ sound: Sound) {
        guard isEnabled(), let player = player(for: sound) else { return }
        // Rewind rather than skip: `play()` on a player that is still sounding carries on from
        // where it is, so two quick copies would otherwise only ever make one snap.
        player.currentTime = 0
        player.play()
    }

    private static func player(for sound: Sound) -> AVAudioPlayer? {
        if let cached = players[sound] { return cached }
        guard let url = url(for: sound),
              let fresh = try? AVAudioPlayer(contentsOf: url) else { return nil }
        fresh.prepareToPlay()
        players[sound] = fresh
        return fresh
    }
}
