import Foundation

/// One GitHub release, as much of it as an update needs: what version it is, what it says, and what
/// there is to download.
///
/// Decoding is forgiving on purpose. Everything but the tag is optional in practice — a release can
/// be published with no notes and no files attached yet — and a release like that should read as
/// "nothing to install here", which the caller can say plainly, rather than as a decoding failure
/// reported to the user as a broken server.
struct ReleaseInfo: Decodable, Equatable {
    let tagName: String
    let body: String
    let assets: [Asset]

    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        body = (try? c.decode(String.self, forKey: .body)) ?? ""      // null or missing → no notes
        assets = (try? c.decode([Asset].self, forKey: .assets)) ?? []
    }

    static func decode(from data: Data) throws -> ReleaseInfo {
        try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    /// The file to download: whichever of the release's attachments is a packaged app.
    ///
    /// xPaste has always shipped a `.zip`, but `.dmg` is accepted too so that changing how a
    /// release is packaged does not strand everyone already running an older build. A `.zip` wins
    /// a tie only because it is the cheaper of the two to unpack — either would install.
    var appArchive: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }
}
