import Foundation

extension Bundle {
    /// The marketing version from Info.plist ("1.1.1"), so nothing in the UI has to hard-code it.
    var appVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
