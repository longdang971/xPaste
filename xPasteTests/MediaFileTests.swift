import XCTest
import AppKit
@testable import xPaste

/// The two decisions a media file forces, both made before anything touches the disk: which player
/// it wants, and which card draws its picture.
final class MediaFileTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    func test_sound_files_ask_for_the_sound_pane() {
        for name in ["song.mp3", "song.m4a", "song.flac", "song.wav", "song.aiff"] {
            XCTAssertEqual(MediaFile.kind(of: url(name)), .audio, name)
        }
    }

    /// An .mp4 conforms to audiovisual content and so does a soundtrack. What decides the pane is
    /// whether there is a picture to show, so video is tested first.
    func test_video_files_ask_for_the_video_pane() {
        for name in ["clip.mp4", "clip.mov", "clip.m4v"] {
            XCTAssertEqual(MediaFile.kind(of: url(name)), .video, name)
        }
    }

    /// `.mkv` is on the list on purpose. macOS registers no type for it and AVFoundation cannot
    /// decode Matroska, so the honest answer is "not a player's problem" — it falls back to the
    /// icon pane rather than to a transport that would never move.
    func test_everything_else_wants_no_player() {
        for name in ["notes.txt", "shot.png", "archive.zip", "Thing.app", "noextension", "clip.mkv"] {
            XCTAssertNil(MediaFile.kind(of: url(name)), name)
        }
    }

    func test_the_clock_reads_the_same_in_every_locale() {
        XCTAssertEqual(MediaFile.timeLabel(0), "0:00")
        XCTAssertEqual(MediaFile.timeLabel(9), "0:09")
        XCTAssertEqual(MediaFile.timeLabel(75), "1:15")
        XCTAssertEqual(MediaFile.timeLabel(277), "4:37")
        XCTAssertEqual(MediaFile.timeLabel(3661), "1:01:01")
    }

    /// A scrubber asks for the label before the file has opened, and `AVAudioPlayer` reports a
    /// nonsense duration for a file it could not read.
    func test_the_clock_survives_a_duration_it_cannot_use() {
        XCTAssertEqual(MediaFile.timeLabel(-1), "0:00")
        XCTAssertEqual(MediaFile.timeLabel(.nan), "0:00")
        XCTAssertEqual(MediaFile.timeLabel(.infinity), "0:00")
    }

    /// A card holding five songs draws the stacked icons, not the cover of whichever one came
    /// first — the same claim the stack exists to avoid making.
    func test_only_a_single_media_file_gives_a_card_its_picture() {
        let one = ClipboardItemCard.mediaSource(type: .file, fileURLs: [url("song.mp3")],
                                                detectedPath: nil)
        XCTAssertEqual(one?.kind, .audio)
        XCTAssertEqual(one?.url, url("song.mp3"))

        XCTAssertNil(ClipboardItemCard.mediaSource(
            type: .file, fileURLs: [url("a.mp3"), url("b.mp3")], detectedPath: nil))
        XCTAssertNil(ClipboardItemCard.mediaSource(
            type: .file, fileURLs: [url("notes.txt")], detectedPath: nil))
        XCTAssertNil(ClipboardItemCard.mediaSource(type: .folder, fileURLs: [url("Music")],
                                                   detectedPath: nil))
    }

    /// The other card that draws a file: a `.text` item whose text turned out to be a path.
    func test_a_text_item_that_is_a_path_to_a_video_gets_the_video_treatment() {
        let source = ClipboardItemCard.mediaSource(type: .text, fileURLs: nil,
                                                   detectedPath: url("clip.mp4"))
        XCTAssertEqual(source?.kind, .video)
    }
}
