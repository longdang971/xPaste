import SwiftUI

/// Recognises colour literals in copied text: `#1e90ff`, `rgb(30, 144, 255)`, `hsl(210, 100%, 56%)`.
///
/// Lifted out of `ClipboardItemCard` so the search filter and the card agree on exactly what
/// counts as a colour — a "Color" chip that hid a card the panel titles "Color" would be a lie.
enum ColorParser {
    /// The longest literal this recognises is about 34 characters (`hsla(360, 100%, 100%, 0.5)`).
    private static let maxLiteralBytes = 64

    /// The colour a text item represents, or nil when it isn't one.
    ///
    /// The length gate is load-bearing, not defensive: this runs on every card body pass, and
    /// `trimmingCharacters` on a half-megabyte paste copies the whole string. `utf8.count` is
    /// O(1) on a native string, while `count` and trimming both walk it.
    static func parse(_ raw: String) -> Color? {
        guard raw.utf8.count <= maxLiteralBytes else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return hex(s) ?? rgb(s) ?? hsl(s)
    }

    static func isColor(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return parse(raw) != nil
    }

    private static func hex(_ s: String) -> Color? {
        guard s.hasPrefix("#") else { return nil }
        var hex = String(s.dropFirst())
        if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        if hex.count == 6, let val = UInt32(hex, radix: 16) {
            return Color(red: Double((val >> 16) & 0xFF) / 255,
                         green: Double((val >> 8) & 0xFF) / 255,
                         blue: Double(val & 0xFF) / 255)
        }
        if hex.count == 8, let val = UInt32(hex, radix: 16) {
            return Color(red: Double((val >> 24) & 0xFF) / 255,
                         green: Double((val >> 16) & 0xFF) / 255,
                         blue: Double((val >> 8) & 0xFF) / 255,
                         opacity: Double(val & 0xFF) / 255)
        }
        return nil
    }

    private static let rgbRegex = try? NSRegularExpression(
        pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([\d.]+))?\s*\)$"#,
        options: .caseInsensitive)
    private static let hslRegex = try? NSRegularExpression(
        pattern: #"^hsla?\(\s*([\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%(?:\s*,\s*([\d.]+))?\s*\)$"#,
        options: .caseInsensitive)

    private static func rgb(_ s: String) -> Color? {
        guard s.count >= 10, s.lowercased().hasPrefix("rgb"),
              let regex = rgbRegex,
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func cap(_ i: Int) -> Double? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return Double(s[r])
        }
        guard let r = cap(1), let g = cap(2), let b = cap(3),
              r <= 255, g <= 255, b <= 255 else { return nil }
        return Color(red: r / 255, green: g / 255, blue: b / 255, opacity: cap(4) ?? 1.0)
    }

    private static func hsl(_ s: String) -> Color? {
        guard s.count >= 10, s.lowercased().hasPrefix("hsl"),
              let regex = hslRegex,
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        func cap(_ i: Int) -> Double? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return Double(s[r])
        }
        guard let h = cap(1), let sat = cap(2), let l = cap(3) else { return nil }
        return fromHSL(h: h / 360, s: sat / 100, l: l / 100, a: cap(4) ?? 1.0)
    }

    private static func fromHSL(h: Double, s: Double, l: Double, a: Double) -> Color {
        if s == 0 { return Color(red: l, green: l, blue: l, opacity: a) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue2rgb(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        return Color(red: hue2rgb(h + 1/3), green: hue2rgb(h), blue: hue2rgb(h - 1/3), opacity: a)
    }
}
