import XCTest
import AppKit
import AVFoundation
@testable import xPaste

final class SoundEffectsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SoundEffectsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testEnabledByDefault() {
        XCTAssertTrue(SoundEffects.isEnabled(defaults: defaults))
    }

    func testRespectsTheSwitch() {
        defaults.set(false, forKey: SoundEffects.defaultsKey)
        XCTAssertFalse(SoundEffects.isEnabled(defaults: defaults))
        defaults.set(true, forKey: SoundEffects.defaultsKey)
        XCTAssertTrue(SoundEffects.isEnabled(defaults: defaults))
    }

    func testCopySoundShipsInTheBundleAndLoads() {
        for sound in SoundEffects.Sound.allCases {
            let url = SoundEffects.url(for: sound)
            XCTAssertNotNil(url, "\(sound) missing from the bundle")
            if let url {
                XCTAssertNoThrow(try AVAudioPlayer(contentsOf: url), "\(sound) did not load")
            }
        }
    }

    func testWakeSignalIsAPlayableAudibleWAV() throws {
        let data = SoundEffects.wakeSignal(duration: 0.15)
        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.duration, 0.15, accuracy: 0.01)
        // Not digital silence: silence was shown not to wake the output.
        XCTAssertTrue(data.dropFirst(44).contains { $0 != 0 })
    }
}
