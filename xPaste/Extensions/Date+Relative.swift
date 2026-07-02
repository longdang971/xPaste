import Foundation

extension Date {
    var relativeString: String {
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.unitsStyle = .short
        return fmt.localizedString(for: self, relativeTo: Date())
    }
}
