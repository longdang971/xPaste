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

    /// An alpha that rounds to a literal "1" (see `number`) must take the opaque form, or the
    /// rendering reads as `rgba(30, 144, 255, 1)` — a colour that visually claims to be opaque while
    /// the classification says otherwise. 0.996 sits in that band: below the old 0.999 cutoff, but
    /// rounds to "1" at the two-decimal precision `number` prints.
    func test_alpha_that_rounds_to_one_takes_the_opaque_form() {
        XCTAssertEqual(ColorFormat.rgb.render(srgb(30/255, 144/255, 255/255, 0.996)), "rgb(30, 144, 255)")
    }

    func test_grey_renders_with_no_saturation() {
        XCTAssertEqual(ColorFormat.hsl.render(srgb(0.5, 0.5, 0.5)), "hsl(0, 0%, 50%)")
    }

    /// The `case r:` branch adds a `+ 6` wrap only when green is less than blue; every other
    /// covered colour has `g == b` (pure red) or lands in a different branch entirely, so this is
    /// the sole test exercising that correction. rgb(200, 50, 150) is red-max with green < blue.
    ///
    /// Expected values worked by hand from the CSS Color 4 / Wikipedia HSL formula, not by running
    /// the code:
    ///   Cmax = 200/255, Cmin = 50/255, Δ = 150/255
    ///   H = 60° × (((G − B) / Δ) mod 6) = 60° × ((−100/150) mod 6) = 60° × 16/3 = 320°
    ///   L = (Cmax + Cmin) / 2 = 250/510 ≈ 49.02% → rounds to 49%
    ///   S = Δ / (1 − |2L − 1|) = (150/255) / (1 − 100/5100) = 0.6 → 60%
    func test_hsl_wraps_hue_when_red_is_max_and_green_is_less_than_blue() {
        XCTAssertEqual(ColorFormat.hsl.render(srgb(200/255, 50/255, 150/255)), "hsl(320, 60%, 49%)")
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
                         srgb(1, 1, 1), srgb(0.2, 0.7, 0.35), srgb(200/255, 50/255, 150/255)] {
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

    /// Covers both ends, not just the middle: a near-transparent alpha, and one sitting just below
    /// the opacity threshold (`0.995`, see `ColorFormat.render`) so that boundary is pinned by a
    /// test rather than only by reading the code.
    func test_alpha_survives_the_round_trip() throws {
        for alpha: Double in [0.02, 0.5, 0.994] {
            for format in [ColorFormat.hex, .rgb, .hsl] {
                let text = format.render(srgb(0.1, 0.2, 0.3, alpha))
                let parsed = try XCTUnwrap(ColorParser.parse(text), text)
                XCTAssertEqual(NSColor(parsed).alphaComponent, alpha, accuracy: 0.01, text)
            }
        }
    }
}
