import XCTest
import AppKit
import SwiftUI
@testable import xPaste

/// Rendering a colour back to a literal — the half `ColorParser` never had; it only ever read them.
final class ColorFormatTests: XCTestCase {

    private func srgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    // MARK: - Rendering

    func test_hex_renders_six_digits_when_opaque() {
        XCTAssertEqual(ColorFormat.hex.render(srgb(30/255, 144/255, 255/255)), "#1e90ff")
    }

    /// Writing `ff` on the end of every opaque colour is technically correct and would annoy anyone
    /// pasting it into CSS.
    func test_hex_gains_an_alpha_pair_only_when_not_opaque() {
        let half = ColorFormat.hex.render(srgb(30/255, 144/255, 255/255, 0.5))
        XCTAssertEqual(half.count, 9, "expected #rrggbbaa, got \(half)")
        XCTAssertTrue(half.hasPrefix("#1e90ff"))
    }

    func test_rgb_renders_whole_channels() {
        XCTAssertEqual(ColorFormat.rgb.render(srgb(30/255, 144/255, 255/255)), "rgb(30, 144, 255)")
    }

    func test_rgb_becomes_rgba_when_not_opaque() {
        XCTAssertEqual(ColorFormat.rgb.render(srgb(0, 0, 0, 0.5)), "rgba(0, 0, 0, 0.5)")
    }

    func test_hsl_renders_degrees_and_percentages() {
        // Pure red: hue 0, fully saturated, half lightness.
        XCTAssertEqual(ColorFormat.hsl.render(srgb(1, 0, 0)), "hsl(0, 100%, 50%)")
    }

    func test_hsl_becomes_hsla_when_not_opaque() {
        XCTAssertTrue(ColorFormat.hsl.render(srgb(1, 0, 0, 0.5)).hasPrefix("hsla("))
    }

    func test_grey_renders_with_no_saturation() {
        XCTAssertEqual(ColorFormat.hsl.render(srgb(0.5, 0.5, 0.5)), "hsl(0, 0%, 50%)")
    }

    /// A colour arriving in a colour space other than sRGB must not throw — reading `.redComponent`
    /// off a Generic Gray colour raises an uncatchable exception, the trap `RichTextRenderer`
    /// documents.
    func test_a_generic_grey_colour_renders_rather_than_raising() {
        XCTAssertFalse(ColorFormat.hex.render(NSColor.black).isEmpty)
    }

    // MARK: - Round trip through the parser

    /// Every rendering has to be something `ColorParser` reads back, or the buttons produce text the
    /// app itself no longer recognises as a colour.
    func test_every_rendering_parses_back_to_the_same_colour() throws {
        for original in [srgb(30/255, 144/255, 255/255), srgb(1, 0, 0), srgb(0, 0, 0),
                         srgb(1, 1, 1), srgb(0.2, 0.7, 0.35)] {
            for format in [ColorFormat.hex, .rgb, .hsl] {
                let text = format.render(original)
                let parsed = try XCTUnwrap(ColorParser.parse(text), "\(text) did not parse back")
                let back = NSColor(parsed).usingColorSpace(.sRGB)!
                XCTAssertEqual(back.redComponent, original.redComponent, accuracy: 0.01, text)
                XCTAssertEqual(back.greenComponent, original.greenComponent, accuracy: 0.01, text)
                XCTAssertEqual(back.blueComponent, original.blueComponent, accuracy: 0.01, text)
            }
        }
    }

    func test_alpha_survives_the_round_trip() throws {
        for format in [ColorFormat.hex, .rgb, .hsl] {
            let text = format.render(srgb(0.1, 0.2, 0.3, 0.5))
            let parsed = try XCTUnwrap(ColorParser.parse(text), text)
            XCTAssertEqual(NSColor(parsed).alphaComponent, 0.5, accuracy: 0.01, text)
        }
    }
}
