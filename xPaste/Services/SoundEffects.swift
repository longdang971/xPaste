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
            player.delegate = warmUp
            player.play()
        }
    }

    static func play(_ sound: Sound) {
        guard isEnabled(), let player = player(for: sound) else { return }
        // Rewind rather than skip: `play()` on a player that is still sounding carries on from
        // where it is, so two quick copies would otherwise only ever make one snap.
        player.delegate = nil
        player.volume = 1
        player.currentTime = 0
        player.play()
    }

    /// Puts a player back to full volume once its silent launch pass has really finished.
    ///
    /// Not a timer. The silent pass starts late — opening the output is the very delay it is there
    /// to absorb — so a timer set to its duration fired while it was still sounding, and turning
    /// the volume up and rewinding at that moment played the snap out loud at launch. Nor `stop()`:
    /// it "undoes the setup provided by prepareToPlay", which left the first copy silent again.
    private final class WarmUp: NSObject, AVAudioPlayerDelegate {
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            player.delegate = nil
            // A copy during the silent pass has already turned it up and played; nothing to undo.
            guard player.volume == 0 else { return }
            player.volume = 1
            player.currentTime = 0
            player.prepareToPlay()
        }
    }
    private static let warmUp = WarmUp()

    private static func player(for sound: Sound) -> AVAudioPlayer? {
        if let cached = players[sound] { return cached }
        guard let url = url(for: sound),
              let fresh = try? AVAudioPlayer(contentsOf: url) else { return nil }
        fresh.prepareToPlay()
        players[sound] = fresh
        return fresh
    }
}
