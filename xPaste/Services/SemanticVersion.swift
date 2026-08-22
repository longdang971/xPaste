import Foundation

/// A release number, comparable so "is there something newer?" is one `>`.
///
/// Deliberately lenient about what it accepts, because it parses two things that are written by
/// hand and are not always written the same way: the `CFBundleShortVersionString` in Info.plist and
/// a release's git tag. A leading `v` is optional (`v1.2.1` and `1.2.1` are the same release), and a
/// missing component is zero (`1.2` is `1.2.0`) — a tag cut short should not read as a downgrade.
///
/// Anything else is `nil` rather than a guess. A version that cannot be read is not comparable, and
/// the caller's job then is to say so, not to offer an update it cannot reason about.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        // Empty subsequences are kept so that "1..2" is rejected rather than read as "1.2".
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (l: SemanticVersion, r: SemanticVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }
}
