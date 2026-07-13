import Foundation

extension Date {
    // A single shared formatter — RelativeDateTimeFormatter is expensive to build, and this is
    // read once per card during list layout. Locale/style are constant, so one instance is safe.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = Locale(identifier: "en_US")
        fmt.unitsStyle = .short
        return fmt
    }()

    var relativeString: String {
        Date.relativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}
