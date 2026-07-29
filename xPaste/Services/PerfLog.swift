import Foundation
import os

/// Main-thread timing for the panel's open/close path.
///
/// Entirely inert unless the process is launched with `XPASTE_PERF=1`, so it can stay in the
/// tree without costing a shipping build anything: every call site is a single Bool test.
///
/// Read the results with:
///     /usr/bin/log show --predicate 'subsystem == "com.user.xPaste"' --last 2m --info
/// (the bare `log` command is shadowed by a shell wrapper on this machine).
enum PerfLog {
    static let enabled = ProcessInfo.processInfo.environment["XPASTE_PERF"] == "1"

    private static let logger = Logger(subsystem: "com.user.xPaste", category: "perf")
    private static var runStart: CFAbsoluteTime = 0
    private static var lastMark: CFAbsoluteTime = 0
    private static var runName = ""
    private static var marks: [(String, Double, Double)] = []

    /// Starts a new timed run. Marks taken afterwards are relative to this point.
    static func begin(_ name: String) {
        guard enabled else { return }
        runStart = CFAbsoluteTimeGetCurrent()
        lastMark = runStart
        runName = name
        marks.removeAll(keepingCapacity: true)
    }

    /// Records the time spent since the previous mark.
    static func mark(_ label: String) {
        guard enabled, runStart > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        marks.append((label, (now - lastMark) * 1000, (now - runStart) * 1000))
        lastMark = now
    }

    /// Times a single synchronous step.
    @discardableResult
    static func step<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let result = body()
        mark(label)
        return result
    }

    /// Prints every mark of the current run, slowest step first in the summary line.
    static func end(_ note: String = "") {
        guard enabled, runStart > 0 else { return }
        let total = (CFAbsoluteTimeGetCurrent() - runStart) * 1000
        logger.info("=== \(runName, privacy: .public) \(note, privacy: .public) total \(total, format: .fixed(precision: 1))ms ===")
        for (label, delta, since) in marks {
            logger.info("  \(String(format: "%7.2f", delta), privacy: .public)ms  @\(String(format: "%7.2f", since), privacy: .public)ms  \(label, privacy: .public)")
        }
        runStart = 0
    }

    // MARK: - Frame timing

    private static var frameTimes: [CFAbsoluteTime] = []
    private static var frameWork: [Double] = []

    static func frameTick() {
        guard enabled else { return }
        frameTimes.append(CFAbsoluteTimeGetCurrent())
    }

    /// Times the actual per-frame move, separately from when the timer fired.
    static func frameWork<T>(_ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        frameWork.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        return result
    }

    static func beginFrames() {
        guard enabled else { return }
        frameTimes.removeAll(keepingCapacity: true)
    }

    /// Reports how evenly the slide's 120Hz timer actually fired. A stall on the main thread
    /// shows up here as one long gap — the frames the animation lost.
    static func endFrames(_ label: String) {
        guard enabled, frameTimes.count > 1 else { return }
        var gaps: [Double] = []
        for i in 1..<frameTimes.count {
            gaps.append((frameTimes[i] - frameTimes[i - 1]) * 1000)
        }
        let late = gaps.filter { $0 > 12 }
        let worst = gaps.max() ?? 0
        let span = (frameTimes.last! - frameTimes.first!) * 1000
        let workAvg = frameWork.isEmpty ? 0 : frameWork.reduce(0, +) / Double(frameWork.count)
        let workMax = frameWork.max() ?? 0
        logger.info("--- \(label, privacy: .public) frames: \(frameTimes.count) over \(span, format: .fixed(precision: 1))ms, worst gap \(worst, format: .fixed(precision: 1))ms, late(>12ms): \(late.count) \(late.map { String(format: "%.1f", $0) }.joined(separator: ","), privacy: .public) | move cost avg \(workAvg, format: .fixed(precision: 2))ms max \(workMax, format: .fixed(precision: 2))ms | per-frame \(frameWork.map { String(format: "%.1f", $0) }.joined(separator: " "), privacy: .public)")
        frameTimes.removeAll(keepingCapacity: true)
        frameWork.removeAll(keepingCapacity: true)
    }

    /// One-off note, outside any run.
    static func note(_ message: String) {
        guard enabled else { return }
        logger.info("· \(message, privacy: .public)")
    }

    /// Times a block and notes it, without disturbing the current run's marks.
    @discardableResult
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let start = CFAbsoluteTimeGetCurrent()
        let result = body()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        if ms > 0.5 { note("\(label): \(String(format: "%.2f", ms))ms") }
        return result
    }
}
