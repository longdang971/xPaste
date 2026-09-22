import SwiftUI
import AppKit
import AVKit
import AVFoundation

/// A sound file, played where you look at it: its cover art, what it is called, and a transport.
///
/// Its own pane rather than `AVPlayerView` with the sound-only chrome, which draws a black
/// rectangle where the artwork should be. A song copied to the clipboard is recognised by its
/// cover, so the cover is what the pane is built around.
struct AudioPreviewPane: View {
    let url: URL
    let info: MediaInfo?

    @StateObject private var player = MediaTransport()

    var body: some View {
        VStack(spacing: 14) {
            artwork
            VStack(spacing: 3) {
                Text(info?.title ?? url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let artist = info?.artist {
                    Text(artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            MediaTransportBar(player: player)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { player.open(url) }
        .onDisappear { player.close() }
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = info?.artwork, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
        } else {
            // A file with no cover still needs something square there, or the transport jumps up
            // the pane and the two kinds of sound file read as two different windows.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 200, height: 200)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 56, weight: .thin))
                        .foregroundStyle(.tertiary)
                }
        }
    }
}

/// A video, played in the pane at the size the pane has.
///
/// `AVPlayerView` with its own floating controls rather than the hand-built transport the sound
/// pane uses: those controls are what every other video on the Mac has, they appear over the
/// picture instead of taking a strip from it, and they bring the volume slider and full screen
/// along without any of it being written here.
struct VideoPreviewPane: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    /// Torn down explicitly. A paused `AVPlayer` left holding the file keeps a decode session and
    /// the file itself alive for as long as the view is retained anywhere, and the popover is
    /// opened and closed on a key press.
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

/// Play, seek and mute for one file, and the clock that drives the scrubber.
///
/// `AVAudioPlayer`, not `AVPlayer`: the file is on disk, its duration is known the moment it opens,
/// and reading the position is a property rather than a time observer.
@MainActor
final class MediaTransport: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: TimeInterval = 0
    @Published var isMuted = false
    /// Where the scrubber sits. Driven by the ticker while playing, and by the user while dragging
    /// — `isScrubbing` is what keeps the two from fighting over the same value.
    @Published var position: TimeInterval = 0
    @Published var isScrubbing = false {
        didSet {
            guard oldValue, !isScrubbing else { return }
            player?.currentTime = position
        }
    }

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    func open(_ url: URL) {
        guard player == nil else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        // Ten a second: fast enough that the scrubber moves rather than steps, cheap enough that
        // it costs nothing while a four-minute song plays.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func close() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        isPlaying = false
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
        } else {
            // Starting again from the end rather than refusing to start: pressing play on a
            // finished track is a request to hear it, not a no-op.
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            player.play()
        }
        isPlaying = player.isPlaying
    }

    func toggleMute() {
        isMuted.toggle()
        player?.volume = isMuted ? 0 : 1
    }

    private func tick() {
        guard let player else { return }
        if !isScrubbing { position = player.currentTime }
        if isPlaying != player.isPlaying { isPlaying = player.isPlaying }
    }
}

/// Play/pause, a scrubber with the clock either side of it, and mute.
struct MediaTransportBar: View {
    @ObservedObject var player: MediaTransport

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 17))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(player.isPlaying ? "Pause" : "Play")

            Text(MediaFile.timeLabel(player.position))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                // Monospaced digits still change width between "0:09" and "0:10"; a fixed column
                // is what stops the slider shifting a point every ten seconds.
                .frame(width: 34, alignment: .trailing)

            Slider(value: $player.position,
                   in: 0...max(player.duration, 0.01),
                   onEditingChanged: { player.isScrubbing = $0 })
                .controlSize(.small)

            Text(MediaFile.timeLabel(player.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)

            Button(action: player.toggleMute) {
                Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(player.isMuted ? "Unmute" : "Mute")
        }
    }
}
