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
    /// the buffers but does not start the stream. Playing each sound once, far too quietly to hear, does.
    static func prepare() {
        guard isEnabled() else { return }
        for sound in Sound.allCases {
            guard let player = player(for: sound), !player.isPlaying else { continue }
            // Not zero. A pass of pure digital silence was not enough: the first copy after
            // launch still came out silent, so whatever holds back the first sound only lets go on
            // a real signal. -60 dB is a real signal nobody can hear.
            player.volume = warmUpVolume
            player.delegate = warmUp
            player.play()
        }
    }

    static func play(_ sound: Sound) {
        guard isEnabled(), let player = player(for: sound) else { return }
        // A copy made in the first moments after launch lands while the silent pass is still
        // opening the output. Sounding it now would lose it the same way the first copy used to be
        // lost; instead it plays the instant the output is ready — a fraction of a second late,
        // and only right after launch.
        if player.delegate === warmUp {
            pendingAfterWarmUp.insert(sound)
            return
        }
        // The output goes back to sleep after a lull, and the snap made a couple of minutes after
        // the last sound was swallowed just like the first one after launch. So after a lull, wake
        // the output with a short inaudible pass first and sound the snap the moment it is done.
        if Date().timeIntervalSince(lastSounded) > idleBeforeRewake {
            pendingAfterWake.insert(sound)
            wakeOutput()
            return
        }
        playNow(player)
    }

    private static func playNow(_ player: AVAudioPlayer) {
        // Rewind rather than skip: `play()` on a player that is still sounding carries on from
        // where it is, so two quick copies would otherwise only ever make one snap.
        player.delegate = nil
        player.volume = 1
        player.currentTime = 0
        player.play()
        lastSounded = Date()
    }

    /// When the app last had sound going to the output. Starts in the past so a copy that beats
    /// the launch pass through any other path still wakes the output.
    private static var lastSounded = Date.distantPast
    /// Well under the ~2 minutes after which the snap was heard to go missing. A copy after a
    /// shorter lull only waits the length of the wake pass; a lost snap is worse.
    private static let idleBeforeRewake: TimeInterval = 30
    /// Copies made while the output is being woken, played as soon as it is awake.
    private static var pendingAfterWake: Set<Sound> = []

    private static func wakeOutput() {
        guard let waker = wakePlayer else {
            // No wake pass to wait on: sound it anyway rather than drop it.
            let pending = pendingAfterWake
            pendingAfterWake.removeAll()
            pending.compactMap { players[$0] }.forEach(playNow)
            return
        }
        guard !waker.isPlaying else { return }
        waker.currentTime = 0
        waker.play()
    }

    /// Sounds the copies waiting on the wake pass once it has really finished — the finish, not a
    /// timer, for the same reason as the launch pass: it starts late by however long waking takes.
    private final class Waker: NSObject, AVAudioPlayerDelegate {
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            let pending = SoundEffects.pendingAfterWake
            SoundEffects.pendingAfterWake.removeAll()
            pending.compactMap { SoundEffects.players[$0] }.forEach(SoundEffects.playNow)
            player.prepareToPlay()
        }
    }
    private static let waker = Waker()
    /// Its own player on a short buffer rather than the snap itself at -60 dB, so a copy after a
    /// lull waits ~150 ms instead of the snap's full 300.
    private static let wakePlayer: AVAudioPlayer? = {
        guard let player = try? AVAudioPlayer(data: wakeSignal(duration: 0.15)) else { return nil }
        player.volume = warmUpVolume
        player.delegate = waker
        player.prepareToPlay()
        return player
    }()

    /// White noise as a 16-bit mono WAV. Noise rather than silence for the same reason the launch
    /// pass is not played at volume zero: only a real signal wakes the output.
    static func wakeSignal(duration: TimeInterval, sampleRate: Int = 44_100) -> Data {
        let frames = Int(Double(sampleRate) * duration)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(frames * 2))
        for _ in 0..<frames { append(Int16.random(in: -16_000...16_000)) }
        return data
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
            player.volume = 1
            player.currentTime = 0
            if let sound = SoundEffects.players.first(where: { $0.value === player })?.key,
               SoundEffects.pendingAfterWarmUp.remove(sound) != nil {
                player.play()
            } else {
                player.prepareToPlay()
            }
            SoundEffects.lastSounded = Date()
        }
    }
    private static let warmUp = WarmUp()
    private static let warmUpVolume: Float = 0.001
    /// Copies made during the silent pass, played as soon as it ends.
    private static var pendingAfterWarmUp: Set<Sound> = []

    private static func player(for sound: Sound) -> AVAudioPlayer? {
        if let cached = players[sound] { return cached }
        guard let url = url(for: sound),
              let fresh = try? AVAudioPlayer(contentsOf: url) else { return nil }
        fresh.prepareToPlay()
        players[sound] = fresh
        return fresh
    }
}
