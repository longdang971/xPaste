import SwiftUI

/// The update window: icon, title and subtitle across the top, the "What's New" box in the middle,
/// a row of buttons at the bottom.
///
/// One window for every stage. The header and the buttons change with `controller.state` while the
/// notes box stays put, so downloading an update never moves the thing the user was reading.
struct UpdateWindowView: View {
    @ObservedObject var controller: UpdateController

    /// The release being handled, kept here rather than read out of the state.
    ///
    /// `.downloading`, `.preparing` and `.installing` do not carry the notes or the version number,
    /// so they have to be held from the moment they arrive with `.available`. Parsed once, on the
    /// way in: during a download `body` runs again every time the progress bar moves.
    @State private var blocks: [ReleaseNoteBlock] = []
    @State private var version = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if showsNotes && !blocks.isEmpty {
                ReleaseNotesView(blocks: blocks)
                    .frame(minHeight: 200)
            } else {
                Spacer(minLength: 0)
            }
            buttons
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 260)
        .onAppear { syncPendingRelease() }
        // The single-argument form: xPaste still deploys to macOS 13, where the two-argument
        // `onChange` does not exist yet.
        .onChange(of: stateName) { _ in syncPendingRelease() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        switch controller.state {
        case .idle:           return "Check for Updates"
        case .checking:       return "Checking for updates…"
        case .upToDate:       return "You're up to date"
        case .available:      return "A new version is available"
        case .downloading:    return "Downloading xPaste \(version)…"
        case .preparing:      return "Preparing the update…"
        case .readyToInstall: return "xPaste \(version) is ready to install"
        case .installing:     return "Installing the update…"
        case .error:          return "Couldn't update"
        }
    }

    private var subtitle: String? {
        switch controller.state {
        case .idle:
            return "You're running version \(Bundle.main.appVersion)."
        case let .upToDate(current):
            return "xPaste \(current) is the latest version."
        case let .available(newVersion, _, _, _):
            return "xPaste \(newVersion) is available — you have \(Bundle.main.appVersion). "
                 + "Would you like to download and install it?"
        case let .readyToInstall(newVersion, _, _):
            return "xPaste \(newVersion) has been downloaded. "
                 + "Install it and relaunch xPaste now?"
        case let .error(message):
            return message
        // The working states get a subtitle too: without one the header is a single line of text
        // beside a 64pt icon, which reads as unfinished.
        case .checking:
            return "Asking GitHub whether anything newer has been published."
        case .downloading:
            return "Leave this window open until the download finishes."
        case .preparing:
            return "Unpacking the download and checking it is really xPaste."
        case .installing:
            return "xPaste will reopen by itself once the new version is in place."
        }
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private var showsNotes: Bool {
        switch controller.state {
        case .available, .downloading, .preparing, .readyToInstall: return true
        case .idle, .checking, .upToDate, .installing, .error: return false
        }
    }

    // MARK: - Buttons

    @ViewBuilder private var buttons: some View {
        switch controller.state {
        case .idle:
            HStack {
                Spacer()
                Button("Close") { close() }
                Button("Check") { Task { await controller.check() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

        case .checking, .preparing, .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Spacer()
            }

        case .upToDate:
            HStack {
                Spacer()
                Button("Close") { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

        case .available:
            HStack {
                // Nothing has been downloaded yet, so dropping back to idle costs nothing.
                Button("Later") { controller.dismissToIdle(); close() }
                Spacer()
                Button("Download and Install") { Task { await controller.startUpdate() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

        case let .downloading(progress, received, total, speed):
            progressRow(progress: progress, received: received, total: total, speed: speed)

        case .readyToInstall:
            HStack {
                // Close the window only. Resetting the controller here would lose track of the
                // build already sitting in staging, and the whole download would have to happen
                // again.
                Button("Later") { close() }
                Spacer()
                Button("Install and Relaunch") { controller.confirmInstall() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }

        case .error:
            HStack {
                Button("Close") { controller.dismissToIdle(); close() }
                Spacer()
                Button("Try Again") { Task { await controller.check() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progressRow(progress: Double, received: Int64, total: Int64,
                             speed: Double) -> some View {
        let clamped = min(max(progress, 0), 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geo.size.width * clamped))
                            .shadow(color: Color.accentColor.opacity(0.35), radius: 3, y: 1)
                            // Progress arrives about every 0.3s, so interpolate between samples and
                            // the bar glides instead of stepping. The animation belongs on the bar
                            // alone: wrapped around the percentage too, SwiftUI cross-fades the
                            // digits and there is a moment of "89" printed over "90".
                            .animation(.linear(duration: 0.3), value: clamped)
                    }
                }
                .frame(height: 10)
                // Fixed width, so 9% becoming 10% cannot squeeze the bar.
                Text("\(Int(clamped * 100))%")
                    .font(.callout.bold().monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
            }

            HStack {
                Text("\(Self.bytes(received)) / \(Self.bytes(total))")
                Spacer()
                Text(speed > 0 ? "\(Self.bytes(Int64(speed)))/s" : "—")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private static func bytes(_ count: Int64) -> String {
        let value = Double(count)
        switch value {
        case ..<1_000:         return "\(count) B"
        case ..<1_000_000:     return String(format: "%.1f KB", value / 1_024)
        case ..<1_000_000_000: return String(format: "%.1f MB", value / 1_048_576)
        default:               return String(format: "%.2f GB", value / 1_073_741_824)
        }
    }

    // MARK: - Holding on to the release across the download

    /// Keyed on the *name* of the state, not its value: `.downloading` changes value every time the
    /// progress moves, and keying on that would re-parse the notes continuously.
    private var stateName: String {
        switch controller.state {
        case .idle:           return "idle"
        case .checking:       return "checking"
        case .upToDate:       return "upToDate"
        case .available:      return "available"
        case .downloading:    return "downloading"
        case .preparing:      return "preparing"
        case .readyToInstall: return "readyToInstall"
        case .installing:     return "installing"
        case .error:          return "error"
        }
    }

    private func syncPendingRelease() {
        switch controller.state {
        case let .available(newVersion, notes, _, _):
            version = newVersion
            blocks = ReleaseNotesMarkdown.parse(notes)
        case let .readyToInstall(newVersion, _, _):
            // Reopened after the download finished: this view's @State is new but the controller's
            // state survived, so at least recover the version. The notes are not in the state to
            // recover.
            version = newVersion
        case .idle, .upToDate, .error:
            version = ""
            blocks = []
        case .checking, .downloading, .preparing, .installing:
            break
        }
    }

    private func close() {
        NotificationCenter.default.post(name: .closeUpdateWindow, object: nil)
    }
}
