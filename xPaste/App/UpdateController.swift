import AppKit
import Foundation

/// Where an update has got to. One value covers the whole flow, so the window has exactly one thing
/// to read and cannot show two stages at once.
enum UpdateState {
    case idle
    case checking
    case upToDate(current: String)
    case available(version: String, notes: String, archiveURL: URL, size: Int64)
    case downloading(progress: Double, received: Int64, total: Int64, speed: Double)
    case preparing
    /// Downloaded and unpacked, waiting for the user to say when to restart. Nothing is replaced
    /// until they do.
    case readyToInstall(version: String, stagingApp: URL, destApp: URL)
    case installing
    case error(message: String)
}

/// Checks GitHub for a newer xPaste, downloads it, and stages it for installation.
///
/// The check is manual and stays manual: nothing here runs on a timer or on launch. A clipboard
/// history that reaches for the network on its own is a surprise nobody asked for, and the menu
/// item is the whole feature.
@MainActor
final class UpdateController: NSObject, ObservableObject, URLSessionDownloadDelegate {
    /// The public repository releases are published to.
    static let releasesRepo = "longdang971/xPaste"

    @Published var state: UpdateState = .idle

    /// `AppDelegate` is not itself actor-isolated, so it cannot construct a `@MainActor` type in a
    /// stored property. Building one touches nothing isolated, so this opts that one step out.
    override nonisolated init() { super.init() }

    private var pendingVersion = ""
    private var pendingSize: Int64 = 0
    private var session: URLSession?
    // Speed is sampled rather than averaged over the whole download, so the figure reflects the
    // connection now instead of dragging a slow start along behind it.
    private var lastSampleBytes: Int64 = 0
    private var lastSampleTime = Date()

    func dismissToIdle() { state = .idle }

    func check() async {
        // Never restart on top of a download or a staged build that is waiting to be installed —
        // the second run would strand the first one's files.
        switch state {
        case .downloading, .preparing, .readyToInstall, .installing: return
        default: break
        }
        state = .checking

        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.releasesRepo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("xPaste", forHTTPHeaderField: "User-Agent")
        // A cached answer would report an update that has already been installed.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .error(message: "The server did not answer. Please try again later.")
                return
            }
            let release = try ReleaseInfo.decode(from: data)
            let current = SemanticVersion(Bundle.main.appVersion) ?? SemanticVersion("0.0.0")!
            guard let latest = SemanticVersion(release.tagName) else {
                state = .error(message: "The latest version number could not be read.")
                return
            }
            guard latest > current else {
                state = .upToDate(current: current.description)
                return
            }
            guard let asset = release.appArchive else {
                state = .error(
                    message: "Version \(latest) has been published but has no download attached yet.")
                return
            }
            state = .available(version: latest.description, notes: release.body,
                               archiveURL: asset.browserDownloadURL, size: asset.size)
        } catch {
            state = .error(message: "Could not reach GitHub: \(error.localizedDescription)")
        }
    }

    func startUpdate() async {
        guard case let .available(version, _, archiveURL, size) = state else { return }
        // The URL came from the network, so it is checked before it is followed: only GitHub's own
        // download hosts, only over TLS.
        guard archiveURL.scheme == "https", let host = archiveURL.host,
              host == "github.com" || host.hasSuffix(".github.com")
                || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
        else {
            state = .error(message: "That download link is not one xPaste will follow.")
            return
        }
        pendingVersion = version
        pendingSize = size
        lastSampleBytes = 0
        lastSampleTime = Date()
        state = .downloading(progress: 0, received: 0, total: size, speed: 0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: archiveURL).resume()
    }

    /// The user pressed Install and Relaunch.
    func confirmInstall() {
        guard case let .readyToInstall(_, staging, destination) = state else { return }
        state = .installing
        if !UpdateInstaller.launchHelperAndQuit(stagingApp: staging, destinationApp: destination) {
            state = .error(message: "The installer could not be started.")
        }
        // On success the app has already been told to quit, so nothing runs past here.
    }

    // MARK: - URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let now = Date()
        Task { @MainActor in
            // A server that sends no length leaves `totalBytesExpectedToWrite` at -1; the size the
            // release listed is the better guess, and what has arrived is the floor under both.
            let total = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : max(self.pendingSize, totalBytesWritten)
            let elapsed = now.timeIntervalSince(self.lastSampleTime)
            var speed = 0.0
            if elapsed >= 0.3 {
                speed = Double(totalBytesWritten - self.lastSampleBytes) / elapsed
                self.lastSampleBytes = totalBytesWritten
                self.lastSampleTime = now
            } else if case let .downloading(_, _, _, previous) = self.state {
                speed = previous          // between samples, keep showing the last figure
            }
            let progress = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            self.state = .downloading(progress: progress, received: totalBytesWritten,
                                      total: total, speed: speed)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // URLSession deletes its temporary file the moment this returns, so the move happens here
        // and not on the hop to the main actor.
        let fm = FileManager.default
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // The extension is carried over: it is how the installer knows what it was handed.
        let suggested = downloadTask.originalRequest?.url?.pathExtension.lowercased()
        let ext = (suggested == "dmg" || suggested == "zip") ? suggested! : "zip"
        let temp = fm.temporaryDirectory
            .appendingPathComponent("xpaste-update-\(UUID().uuidString).\(ext)")
        let moved = (try? fm.moveItem(at: location, to: temp)) != nil

        Task { @MainActor in
            guard (200...299).contains(status) else {
                if moved { try? fm.removeItem(at: temp) }
                self.state = .error(message: "The download failed (server returned \(status)).")
                return
            }
            guard moved else {
                self.state = .error(message: "The downloaded file could not be saved.")
                return
            }
            self.prepare(archiveAt: temp)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error {
                self.state = .error(message: "The download failed: \(error.localizedDescription)")
            }
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
    }

    // MARK: - Unpacking

    /// Unpacks the download and stops at `.readyToInstall`, which is as far as this goes without
    /// being asked: replacing the app quits it, and quitting an app is the user's call.
    private func prepare(archiveAt archive: URL) {
        state = .preparing
        let destination = Bundle.main.bundleURL

        // Somewhere xPaste cannot write to — a copy still in Downloads, say. The archive is left
        // where it is and handed over, because installing by hand is the one thing that still works.
        guard UpdateInstaller.canReplace(bundleURL: destination) else {
            NSWorkspace.shared.activateFileViewerSelecting([archive])
            state = .error(message: "xPaste cannot write to the folder it is in. "
                         + "The download has been revealed in Finder so you can install it yourself.")
            return
        }
        // Past that guard the archive has served its purpose on every path out: the app is staged
        // out of it on success, and no failure below has any further use for it.
        defer { try? FileManager.default.removeItem(at: archive) }
        do {
            let staged = try UpdateInstaller.stageApp(fromArchiveAt: archive)
            state = .readyToInstall(version: pendingVersion, stagingApp: staged,
                                    destApp: destination)
        } catch {
            state = .error(message: "The update could not be prepared: \(error.localizedDescription)")
        }
    }
}
