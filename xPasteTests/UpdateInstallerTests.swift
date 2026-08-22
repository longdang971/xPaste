import XCTest
@testable import xPaste

/// Unpacking a downloaded release. The checks here are the ones standing between a bad download and
/// an app directory with nothing usable left in it, so they are tested against real archives built
/// in a temporary directory rather than against stubs.
final class UpdateInstallerTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("xpaste-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A minimal app bundle: enough of one for the identity check to have something to read.
    @discardableResult
    private func makeApp(named name: String, bundleID: String, in directory: URL) throws -> URL {
        let app = directory.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "xPaste"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml,
                                                      options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    /// Zipped the way a release is: `ditto -c -k --keepParent`, so the archive holds the bundle
    /// itself rather than its contents loose.
    private func zip(_ app: URL, to zipURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zipURL.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "ditto could not build the test archive")
    }

    func testStagesTheAppOutOfAZip() throws {
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(named: "xPaste.app", bundleID: UpdateInstaller.expectedBundleIdentifier,
                    in: source)
        let archive = scratch.appendingPathComponent("release.zip")
        try zip(source.appendingPathComponent("xPaste.app"), to: archive)

        let staged = try UpdateInstaller.stageApp(
            fromArchiveAt: archive, into: scratch.appendingPathComponent("stage", isDirectory: true))

        XCTAssertEqual(staged.lastPathComponent, "xPaste.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(UpdateInstaller.bundleIdentifier(ofAppAt: staged),
                       UpdateInstaller.expectedBundleIdentifier)
    }

    /// The check that matters most: a release with the wrong file attached must not be installed
    /// over xPaste, which would leave the user with neither app.
    func testRefusesAnAppThatIsNotXPaste() throws {
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try makeApp(named: "Impostor.app", bundleID: "com.example.impostor", in: source)
        let archive = scratch.appendingPathComponent("wrong.zip")
        try zip(source.appendingPathComponent("Impostor.app"), to: archive)

        XCTAssertThrowsError(try UpdateInstaller.stageApp(
            fromArchiveAt: archive,
            into: scratch.appendingPathComponent("stage", isDirectory: true)))
    }

    func testRefusesAnArchiveWithNoAppInIt() throws {
        let source = scratch.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("not an app".utf8).write(to: source.appendingPathComponent("readme.txt"))
        let archive = scratch.appendingPathComponent("empty.zip")
        try zip(source.appendingPathComponent("readme.txt"), to: archive)

        XCTAssertThrowsError(try UpdateInstaller.stageApp(
            fromArchiveAt: archive,
            into: scratch.appendingPathComponent("stage", isDirectory: true)))
    }

    func testRefusesAFormatItDoesNotUnderstand() {
        let archive = scratch.appendingPathComponent("release.tar.gz")
        try? Data("x".utf8).write(to: archive)
        XCTAssertThrowsError(try UpdateInstaller.stageApp(
            fromArchiveAt: archive,
            into: scratch.appendingPathComponent("stage", isDirectory: true)))
    }

    func testFindsAnAppBesideOtherFiles() throws {
        try makeApp(named: "xPaste.app", bundleID: UpdateInstaller.expectedBundleIdentifier,
                    in: scratch)
        try Data("x".utf8).write(to: scratch.appendingPathComponent("README.txt"))
        XCTAssertEqual(UpdateInstaller.appBundle(in: scratch)?.lastPathComponent, "xPaste.app")
    }

    func testReportsNoAppWhenThereIsNone() throws {
        try Data("x".utf8).write(to: scratch.appendingPathComponent("README.txt"))
        XCTAssertNil(UpdateInstaller.appBundle(in: scratch))
    }

    /// It is the containing folder that has to be writable — the swap moves the old bundle aside
    /// and copies the new one in beside it.
    func testCanReplaceAsksAboutTheContainingFolder() {
        XCTAssertTrue(UpdateInstaller.canReplace(
            bundleURL: scratch.appendingPathComponent("xPaste.app")))
        XCTAssertFalse(UpdateInstaller.canReplace(
            bundleURL: URL(fileURLWithPath: "/usr/lib/xPaste.app")))
    }
}
