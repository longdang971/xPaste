import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// What a media file carries inside it: the cover art or opening frame a card draws instead of a
/// generic icon, and the tags the preview names it by.
///
/// `Data` rather than `NSImage` for the artwork, because this is read on a detached task and the
/// bytes are what can cross it. The caller decodes.
struct MediaInfo: Sendable {
    var title: String?
    var artist: String?
    var artwork: Data?
    /// Seconds, or nil when the file would not open.
    var duration: TimeInterval?
}

/// Whether a file is something to play, and which kind of player it wants.
enum MediaKind {
    case audio, video
}

enum MediaFile {
    /// Which player a file wants, or nil for a file that is not one.
    ///
    /// Asked of the extension, not of the disk: this runs on the card's `.task` for every file item
    /// that scrolls into view, and the answer decides whether to touch the file at all. `UTType`
    /// rather than a list of extensions, so .m4a, .flac, .mkv and whatever comes next are all
    /// covered by the one rule the system already knows.
    ///
    /// Video is tested first. An .mp4 conforms to `audiovisualContent` and so would a soundtrack —
    /// the distinction that matters is whether there is a picture to show.
    static func kind(of url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return nil
    }

    /// Which player a file wants *and* can actually use.
    ///
    /// `kind(of:)` reads the extension, which says what the file is meant to be; this asks
    /// AVFoundation whether it can decode it. The two disagree often enough to matter — .wma and
    /// .flv have types the system knows and no decoder behind them — and the difference on screen
    /// is a transport that will never move. Nil means "show it as a file instead".
    ///
    /// Not merged into `kind(of:)`: that one is called from a card's `.task` for every file
    /// scrolling past, and this one opens the file.
    static func playableKind(of url: URL) async -> MediaKind? {
        guard let kind = kind(of: url) else { return nil }
        guard (try? await AVURLAsset(url: url).load(.isPlayable)) == true else { return nil }
        return kind
    }

    /// Reads the cover art and tags out of a sound file.
    ///
    /// One pass for all of it: loading an asset's metadata opens and parses the file, and the card
    /// wants the artwork while the preview wants the tags as well — doing it twice would parse the
    /// same header twice for one item.
    static func readAudio(_ url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        var info = MediaInfo()
        info.duration = await seconds(of: asset)
        guard let metadata = try? await asset.load(.commonMetadata) else { return info }
        var artist: String?
        var album: String?
        for item in metadata {
            switch item.commonKey {
            case .commonKeyArtwork:
                if info.artwork == nil { info.artwork = try? await item.load(.dataValue) }
            case .commonKeyTitle:
                info.title = nonEmpty(try? await item.load(.stringValue)) ?? info.title
            case .commonKeyArtist:
                artist = nonEmpty(try? await item.load(.stringValue)) ?? artist
            case .commonKeyAlbumName:
                album = nonEmpty(try? await item.load(.stringValue)) ?? album
            default:
                continue
            }
        }
        // Collected separately and decided at the end: the items come in the file's order, so
        // picking as they arrive would let an album tag placed after an artist tag overwrite it.
        info.artist = artist ?? album
        return info
    }

    /// A frame from near the start of a video, for the card to draw.
    ///
    /// A second in rather than at zero, because a great many videos open on black or on a fade, and
    /// a black rectangle is the one thing a thumbnail must not be. The tolerances are wide on
    /// purpose: any nearby keyframe will do, and asking for an exact time makes the generator
    /// decode forward to it.
    static func posterFrame(for url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    private static func seconds(of asset: AVURLAsset) async -> TimeInterval? {
        guard let duration = try? await asset.load(.duration) else { return nil }
        let value = CMTimeGetSeconds(duration)
        return value.isFinite && value > 0 ? value : nil
    }

    private static func nonEmpty(_ value: String??) -> String? {
        guard let value = value ?? nil, !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return value
    }

    /// `m:ss`, or `h:mm:ss` once there is an hour of it.
    ///
    /// Written by hand rather than through a `DateComponentsFormatter`: this is the label beside a
    /// scrubber, where the digits must not drift with the locale — a Vietnamese locale writes the
    /// same duration as "3 phút 15 giây", which is not what goes there.
    static func timeLabel(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}
