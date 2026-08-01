import Foundation

/// The stops on the "keep history" slider, shared by Settings and the Quick Start window
/// so both label the same stored `keepHistoryIndex` the same way.
enum HistoryRetention {
    /// Slider stops, shortest first. The index is what's stored in `keepHistoryIndex`.
    static let labels = ["Day", "Week", "Month", "Year", "Forever"]

    static let lastIndex = labels.count - 1

    /// Index used when nothing has been chosen yet — keep everything.
    static let defaultIndex = lastIndex

    /// Value shown next to the slider: "1 month", "Forever", …
    static func summary(for index: Int) -> String {
        guard labels.indices.contains(index) else { return labels[lastIndex] }
        return index == lastIndex ? labels[lastIndex] : "1 \(labels[index].lowercased())"
    }
}
