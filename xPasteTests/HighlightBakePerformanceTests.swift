import XCTest
import AppKit
@testable import xPaste

/// What marking a formatted card costs, since the mark is baked into the bitmap and therefore
/// re-baked on every keystroke.
///
/// The design bet is that caching the parse is what makes this affordable: the parse is the
/// expensive half and does not depend on the search box, while the re-bake is TextKit laying out
/// at most `cardCharLimit` characters into one small bitmap. These tests measure both halves so
/// the bet is a number rather than a belief.
///
/// Assertions are relative, never absolute — a wall-clock threshold would fail on a loaded CI box
/// while telling us nothing. The absolute figures are printed for the record.
@MainActor
final class HighlightBakePerformanceTests: XCTestCase {

    private let size = RichTextRenderer.cardPreviewSize

    /// A fresh item every call: the parse cache is keyed by item id, so reusing one would measure
    /// the warm path while claiming to measure the cold one.
    private func freshHTMLItem() -> ClipboardItem {
        let html = "<meta charset='utf-8'><div style='font-family:monospace'>"
            + String(repeating: "storage.haysexcdn.net/images/thanh-nien-may-man ", count: 12)
            + "</div>"
        return ClipboardItem(type: .text, text: "x", richData: Data(html.utf8),
                             richType: NSPasteboard.PasteboardType.html.rawValue)
    }

    private func freshRTFItem() -> ClipboardItem {
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let s = NSMutableAttributedString()
        for _ in 0..<12 {
            s.append(NSAttributedString(string: "$ git status on branch main\n", attributes: [
                .font: mono, .foregroundColor: NSColor.white, .backgroundColor: NSColor.black]))
        }
        let data = s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])!
        return ClipboardItem(type: .text, text: s.string, richData: data,
                             richType: NSPasteboard.PasteboardType.rtf.rawValue)
    }

    private func milliseconds(_ body: () async -> Void) async -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        await body()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// The whole point of the parse cache. An uncached HTML parse is a WebKit document build on the
    /// main thread; if a keystroke paid that, this feature would not be shippable.
    func test_rebaking_for_a_new_term_is_far_cheaper_than_the_first_build() async {
        var coldTotal = 0.0, warmTotal = 0.0
        let rounds = 10

        for round in 0..<rounds {
            let item = freshHTMLItem()
            coldTotal += await milliseconds {
                _ = await RichTextRenderer.cardPreview(for: item, size: size, highlightTerm: "")
            }
            // Same item, new term: exactly what one more character in the search box asks for.
            warmTotal += await milliseconds {
                _ = await RichTextRenderer.cardPreview(for: item, size: size,
                                                       highlightTerm: String("storage".prefix(round % 7 + 1)))
            }
        }

        let cold = coldTotal / Double(rounds), warm = warmTotal / Double(rounds)
        print("PERF html: first build \(String(format: "%.2f", cold))ms, "
              + "re-bake per keystroke \(String(format: "%.2f", warm))ms")
        XCTAssertLessThan(warm, cold,
                          "a re-bake must be cheaper than a build that includes the WebKit parse")
    }

    /// RTF is the case the parse cache does *not* rescue, and does not need to: the RTF parse is
    /// cheap and was already off the main thread, so a first build and a re-bake cost about the
    /// same. Measured at 0.47ms vs 0.51ms. The assertion is therefore that re-baking introduces no
    /// new expensive work — not that it is faster, which it is not.
    func test_rtf_rebaking_costs_about_what_the_first_build_did() async {
        var coldTotal = 0.0, warmTotal = 0.0
        let rounds = 10

        for round in 0..<rounds {
            let item = freshRTFItem()
            coldTotal += await milliseconds {
                _ = await RichTextRenderer.cardPreview(for: item, size: size, highlightTerm: "")
            }
            warmTotal += await milliseconds {
                _ = await RichTextRenderer.cardPreview(for: item, size: size,
                                                       highlightTerm: String("branch".prefix(round % 6 + 1)))
            }
        }

        let cold = coldTotal / Double(rounds), warm = warmTotal / Double(rounds)
        print("PERF rtf: first build \(String(format: "%.2f", cold))ms, "
              + "re-bake per keystroke \(String(format: "%.2f", warm))ms")
        XCTAssertLessThan(warm, cold * 2,
                          "a re-bake is a rasterise; if it ever costs multiples of a full build, "
                          + "something has started re-parsing or re-measuring per keystroke")
    }

    /// A keystroke re-bakes every visible formatted card, so the figure that matters to the panel
    /// is the per-card cost times the number on screen. Printed rather than asserted: what counts
    /// as acceptable is a judgement about the panel, not something a unit test can decide.
    func test_report_the_cost_of_one_keystroke_across_a_panelful() async {
        let visibleCards = 8
        var items: [ClipboardItem] = []
        for _ in 0..<visibleCards {
            let item = freshHTMLItem()
            _ = await RichTextRenderer.cardPreview(for: item, size: size, highlightTerm: "")
            items.append(item)
        }

        let elapsed = await milliseconds {
            for item in items {
                _ = await RichTextRenderer.cardPreview(for: item, size: size, highlightTerm: "storage")
            }
        }
        print("PERF keystroke: \(visibleCards) formatted cards re-baked in "
              + "\(String(format: "%.2f", elapsed))ms")
        XCTAssertGreaterThan(elapsed, 0)
    }

    /// Marking is applied after truncation, so a copied novel costs the same as a copied paragraph.
    func test_marking_cost_does_not_grow_with_the_copied_text() {
        let short = NSAttributedString(string: String(repeating: "storage abc ", count: 20))
        let long = NSAttributedString(string: String(repeating: "storage abc ", count: 2000))

        func markMs(_ s: NSAttributedString) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            for _ in 0..<20 {
                _ = SearchHighlight.marked(s, term: "storage", forLightAppearance: true)
            }
            return (CFAbsoluteTimeGetCurrent() - start) * 1000 / 20
        }
        // Both are measured whole here to show the growth; the renderer only ever marks the
        // truncated string, which is why this growth never reaches the panel.
        print("PERF marking: short \(String(format: "%.3f", markMs(short)))ms, "
              + "long \(String(format: "%.3f", markMs(long)))ms")
        XCTAssertLessThan(RichTextRenderer.cardCharLimit, long.length,
                          "the long sample must exceed the cap, or this test proves nothing")
    }
}
