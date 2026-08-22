import AppKit
import Foundation

/// Unpacks a downloaded release and swaps it in for the running app.
///
/// The swap cannot happen from inside the app being replaced, so the last step writes a small shell
/// script, launches it detached, and quits: the script waits for this process to go away, moves the
/// old bundle aside, copies the new one in, and reopens it. Everything before that point is done
/// while the app is still running and still able to say what went wrong.
enum UpdateInstaller {
    struct InstallerError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The bundle identifier a downloaded app must have before it is allowed to replace this one.
    static let expectedBundleIdentifier = "com.user.xPaste"

    /// Where a downloaded build is unpacked to wait for the swap. Not private so that tests can
    /// pass `stageApp` somewhere disposable instead of the real one.
    static var updateDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xPaste/Update", isDirectory: true)
    }

    /// Whether the app can be replaced where it stands.
    ///
    /// It is the *containing* directory that has to be writable — the swap moves the bundle aside
    /// and copies a new one in beside it, rather than writing through the old one.
    static func canReplace(bundleURL: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
    }

    /// Unpacks `archive` and leaves an independent copy of the new app in the update directory.
    ///
    /// Independent matters: whatever the archive was — a mounted image, a temporary unzip — is gone
    /// by the time the swap runs, so what the swap copies from has to be ours and has to outlive it.
    static func stageApp(fromArchiveAt archive: URL, into directory: URL = updateDir) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        switch archive.pathExtension.lowercased() {
        case "zip": return try stageFromZip(archive, into: directory)
        case "dmg": return try stageFromDMG(archive, into: directory)
        default: throw InstallerError(message: "Unrecognised download format.")
        }
    }

    /// `ditto -x -k` rather than `unzip`: it is what packaged the release, and it is the only
    /// unarchiver that preserves the resource forks and symlinks inside an app bundle intact.
    private static func stageFromZip(_ zip: URL, into directory: URL) throws -> URL {
        let unpacked = directory.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        _ = try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let app = appBundle(in: unpacked) else {
            throw InstallerError(message: "No app was found in the download.")
        }
        return try verified(app)
    }

    private static func stageFromDMG(_ dmg: URL, into directory: URL) throws -> URL {
        let mount = try mountDMG(at: dmg)
        defer { detach(mount) }                    // on every exit, thrown or not
        guard let app = appBundle(in: mount) else {
            throw InstallerError(message: "No app was found in the download.")
        }
        // Copied out from under the mount point, which `defer` is about to unmount.
        let staged = directory.appendingPathComponent(app.lastPathComponent)
        _ = try run("/usr/bin/ditto", [app.path, staged.path])
        return try verified(staged)
    }

    /// Refuses anything that is not this app. A release that attached the wrong file would
    /// otherwise be installed over xPaste and leave the user with neither.
    private static func verified(_ app: URL) throws -> URL {
        guard bundleIdentifier(ofAppAt: app) == expectedBundleIdentifier else {
            throw InstallerError(message: "The download is not xPaste.")
        }
        return app
    }

    static func bundleIdentifier(ofAppAt app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let contents = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return contents["CFBundleIdentifier"] as? String
    }

    /// The first `.app` directly inside `directory`, skipping the `__MACOSX` bookkeeping folder a
    /// zip can carry.
    static func appBundle(in directory: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    static func mountDMG(at dmg: URL) throws -> URL {
        let out = try run("/usr/bin/hdiutil",
                          ["attach", dmg.path, "-nobrowse", "-readonly", "-plist"])
        guard let data = out.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { throw InstallerError(message: "The download could not be opened.") }
        guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            // `attach` succeeded — the image is a /dev/diskN device now — but nothing mounted, so
            // there is no path to detach by later. Let go of the device before giving up.
            for device in entities.compactMap({ $0["dev-entry"] as? String }) {
                _ = try? run("/usr/bin/hdiutil", ["detach", device, "-force"])
            }
            throw InstallerError(message: "The download could not be opened.")
        }
        return URL(fileURLWithPath: mount)
    }

    static func detach(_ mountPoint: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
    }

    /// Hands the swap to a detached script and quits so it can proceed.
    ///
    /// `xattr -cr` on the way in matters more here than it looks: the download arrives quarantined,
    /// and xPaste is signed with a self-signed certificate, so a quarantined copy is one Gatekeeper
    /// refuses outright. Returns `false` only if the script could not be started — the app is then
    /// still running and the caller still has something to say.
    @discardableResult
    static func launchHelperAndQuit(stagingApp: URL, destinationApp: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = #"""
        #!/bin/bash
        PID="$1"; STAGING="$2"; DEST="$3"
        i=0
        TIMED_OUT=0
        while kill -0 "$PID" 2>/dev/null; do
          sleep 0.2
          i=$((i+1))
          if [ "$i" -ge 300 ]; then TIMED_OUT=1; break; fi
        done
        if [ "$TIMED_OUT" -eq 1 ]; then
          # Still running after ~60s. Never overwrite a live bundle; abandon the update intact.
          /bin/rm -rf "$STAGING"
          exit 1
        fi
        BACKUP="${DEST}.backup-$$"
        if [ -d "$DEST" ]; then
          if ! /bin/mv "$DEST" "$BACKUP"; then
            /usr/bin/open "$DEST"
            exit 1
          fi
        fi
        if /usr/bin/ditto "$STAGING" "$DEST"; then
          /usr/bin/xattr -cr "$DEST" 2>/dev/null
          /bin/rm -rf "$BACKUP"
          /bin/rm -rf "$STAGING"
          /usr/bin/open "$DEST"
        else
          /bin/rm -rf "$DEST"
          if [ -d "$BACKUP" ]; then
            if /bin/mv "$BACKUP" "$DEST"; then
              /usr/bin/open "$DEST"
            else
              /usr/bin/open "$BACKUP"
            fi
          fi
        fi
        """#
        let scriptURL = updateDir.appendingPathComponent("install.sh")
        do {
            try FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [scriptURL.path, String(pid), stagingApp.path, destinationApp.path]
            try task.run()
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw InstallerError(message: "\(launchPath) failed (code \(task.terminationStatus)).")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
