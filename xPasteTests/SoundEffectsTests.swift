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
}
