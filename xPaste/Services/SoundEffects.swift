import AppKit
import AVFoundation

/// The short cue xPaste plays when it captures a copy: a synthesised paper snap shipped in
/// `Resources/Sounds`, soft enough not to sound like a system alert. Pasting is silent — a paste
/// sound was tried and dropped.
///
/// Played through one `AVAudioEngine` rather than `AVAudioPlayer`s. On a USB output such as a
/// Studio Display's speakers, the start of whatever sound first reaches an idle output is swallowed
/// — after launch and again after a lull of a minute or two — and the snap's whole body is its
/// first 40 ms. Only a real signal wakes it (a pass of digital silence did not). The players
/// version woke it with a separate inaudible pass and started the snap when that pass finished, but
/// the two were separate streams: the output could go idle in the gap between them, and the first
/// copy still came out silent. Here the wake noise and the snap are scheduled back to back on the
/// same player node, so they reach the output as one continuous stream: whatever is swallowed is
/// noise, and the snap follows with no gap.
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

    // Main thread only, all of it.
    private static let engine = AVAudioEngine()
    private static let node = AVAudioPlayerNode()
    private static var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private static var wakeBuffer: AVAudioPCMBuffer?
    private static var isSetUp = false

    /// When the output last had signal going to it (snap or wake noise); past `idleBeforeRewake`
    /// the output is treated as asleep.
    private static var lastSignal = Date.distantPast
    /// Well under the ~2 minutes after which the snap was heard to go missing.
    private static let idleBeforeRewake: TimeInterval = 30
    /// As long as the launch pass that was shown to wake the output: the snap's own 300 ms.
    static let wakeDuration: TimeInterval = 0.3
    /// -60 dB: a real signal nobody can hear.
    static let wakeLevel: Float = 0.001
    /// While the wake noise is still playing: a snap is queued behind it rather than cutting it off.
    private static var wakingUntil = Date.distantPast
    private static var snapQueuedBehindWake = false
    private static var idleStop: DispatchWorkItem?
    private static var commandMonitor: Any?

    /// Loads the sounds, wakes the output and starts watching ⌘. Called at launch.
    ///
    /// Waking only once a copy had been seen made the snap after launch or after a lull come about
    /// a second late: opening the USB output and the wake noise both came after the copy. So the
    /// output is woken at launch, and again whenever ⌘ goes down while it is asleep — ⌘ is pressed
    /// before C, which gives the wake a head start on the copy it precedes.
    static func prepare() {
        guard isEnabled() else { return }
        setUp()
        wake()
        if commandMonitor == nil {
            commandMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                guard event.modifierFlags.contains(.command), isEnabled() else { return }
                wake()
            }
        }
    }

    /// Sends the inaudible wake noise if the output may be asleep. Harmless if it is not.
    static func wake() {
        guard isSetUp, let noise = wakeBuffer else { return }
        guard !engine.isRunning || Date().timeIntervalSince(lastSignal) > idleBeforeRewake else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        node.scheduleBuffer(noise, at: nil, options: .interrupts)
        if !node.isPlaying { node.play() }
        let end = Date().addingTimeInterval(wakeDuration)
        wakingUntil = end
        snapQueuedBehindWake = false
        lastSignal = end
        scheduleIdleStop()
    }

    static func play(_ sound: Sound) {
        guard isEnabled() else { return }
        setUp()
        guard let snap = buffers[sound] else { return }
        wake()
        guard engine.isRunning else { return }
        if Date() < wakingUntil {
            // Behind the wake noise, so it sounds the instant the output is awake.
            guard !snapQueuedBehindWake else { return }
            node.scheduleBuffer(snap, at: nil)
            snapQueuedBehindWake = true
        } else {
            // Interrupts, so two quick copies make two snaps rather than one.
            node.scheduleBuffer(snap, at: nil, options: .interrupts)
            if !node.isPlaying { node.play() }
            lastSignal = Date()
            scheduleIdleStop()
        }
    }

    /// Lets the output go once it would need waking again anyway, so an idle xPaste does not keep
    /// the audio device running.
    private static func scheduleIdleStop() {
        idleStop?.cancel()
        let work = DispatchWorkItem {
            node.stop()
            engine.stop()
        }
        idleStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleBeforeRewake + 1, execute: work)
    }

    private static func setUp() {
        guard !isSetUp else { return }
        var loaded: [Sound: AVAudioPCMBuffer] = [:]
        for sound in Sound.allCases {
            guard let url = url(for: sound),
                  let file = try? AVAudioFile(forReading: url),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)),
                  (try? file.read(into: buffer)) != nil else { continue }
            loaded[sound] = buffer
        }
        guard let format = loaded.values.first?.format else { return }
        buffers = loaded
        wakeBuffer = wakeSignal(format: format, duration: wakeDuration)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        // A change of output device stops the engine; the next copy starts it again and, since
        // the new device is asleep as far as anyone knows, wakes it first.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: .main) { _ in
            lastSignal = .distantPast
        }
        isSetUp = true
    }

    /// Inaudible white noise in the snap's own format. Noise rather than silence: only a real
    /// signal wakes the output.
    static func wakeSignal(format: AVAudioFormat, duration: TimeInterval) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                channels[channel][frame] = Float.random(in: -wakeLevel...wakeLevel)
            }
        }
        return buffer
    }
}
