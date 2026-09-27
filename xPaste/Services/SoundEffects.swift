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

    /// Loads the sounds and opens the audio output ahead of time. Called at launch.
    ///
    /// The first sound a process plays is the one that opens its stream to the output device, and
    /// on a USB output such as a Studio Display's speakers that takes long enough to swallow the
    /// snap — whose whole body is its first 40 ms. So the first copy after launch made no sound,
    /// and every later one did, however long the gap. `prepareToPlay` alone did not help: it fills
    /// the buffers but does not start the stream. Playing each sound once at zero volume does.
    static func prepare() {
        guard isEnabled() else { return }
        for sound in Sound.allCases {
            guard let player = player(for: sound), !player.isPlaying else { continue }
            player.volume = 0
            player.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + player.duration + 0.1) {
                // A copy made in the meantime turned the volume back up; leave that one playing.
                guard player.volume == 0 else { return }
                // Let the silent pass run out on its own and never call `stop()` here: `stop()`
                // "undoes the setup provided by prepareToPlay", which put the first copy straight
                // back to opening the output from scratch — and silent again.
                player.volume = 1
                player.currentTime = 0
                player.prepareToPlay()
            }
        }
    }

    static func play(_ sound: Sound) {
        guard isEnabled(), let player = player(for: sound) else { return }
        // Rewind rather than skip: `play()` on a player that is still sounding carries on from
        // where it is, so two quick copies would otherwise only ever make one snap.
        player.volume = 1
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
