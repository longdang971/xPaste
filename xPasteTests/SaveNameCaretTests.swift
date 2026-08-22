import XCTest
@testable import xPaste

/// The nudge that puts the Save dialog's caret in front of the extension.
///
/// Only the decision is testable — the keystroke itself goes to another process — but the decision
/// is where both bugs were. The first version pressed once, blind, on a fixed timer. The second
/// gated the press on the dialog being visible and the app being frontmost, and a traced run showed
/// neither is knowable here: the panel is out of process and reports itself invisible, and the app
/// never activates behind a `nonactivatingPanel`. So it waited fifteen ticks and never pressed.
/// Stopping the run when the dialog closes is the timer's job in `AppDelegate`, not a decision
/// here — `runModal` returning is the only signal, and it is not one this can be handed.
final class SaveNameCaretTests: XCTestCase {

    private func step(presses: Int = 0, name: String = ".png") -> SaveNameCaret.Step {
        SaveNameCaret.step(presses: presses, currentName: name, suggestedName: ".png")
    }

    /// The regression that matters: nothing about the app's state may hold the press back, because
    /// nothing about the app's state can be read truthfully while this dialog is up.
    func testPressesWithoutWaitingOnAnythingElse() {
        XCTAssertEqual(step(), .press)
    }

    func testKeepsPressingUpToTheLimit() {
        for presses in 0..<SaveNameCaret.pressLimit {
            XCTAssertEqual(step(presses: presses), .press, "press \(presses)")
        }
        XCTAssertEqual(step(presses: SaveNameCaret.pressLimit), .stop)
    }

    func testStopsAsSoonAsTheNameIsNoLongerTheSuggestion() {
        XCTAssertEqual(step(name: "notes.png"), .stop)
        XCTAssertEqual(step(name: ".png.png"), .stop)
        XCTAssertEqual(step(name: ""), .stop)
    }

    /// A field editor in another process may not be ready for the first press, so the run has to
    /// last long enough to try again — and short enough not to still be typing into a dialog the
    /// user has moved on inside of.
    func testTheRunIsLongEnoughToRetryAndShortEnoughToBeHarmless() {
        let window = Double(SaveNameCaret.pressLimit) * SaveNameCaret.tickInterval
        XCTAssertGreaterThanOrEqual(window, 0.5)
        XCTAssertLessThanOrEqual(window, 1.0)
    }
}
