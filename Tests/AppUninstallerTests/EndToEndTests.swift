import Foundation
import Testing
@testable import AppUninstaller
@testable import JunkCleanup

/// Installs a throwaway app with real preferences, caches, support files and a loaded launch agent in the real
/// home folder, uninstalls it, and checks that everything is gone. Opt-in: `MACCLEANER_E2E=1 make test`.
/// The removed probe files end up in the Trash.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MACCLEANER_E2E"] == "1"), .serialized)
struct EndToEndUninstallTests {
    static let bundleID = "com.maccleaner.e2eprobe"

    @Test func uninstallsAProbeAppCompletely() async throws {
        let fm = FileManager.default
        let home = JunkPaths.current.home
        let app = home.appending(path: "Applications/MacCleaner E2E Probe.app")
        let support = home.appending(path: "Library/Application Support/MacCleaner E2E Probe")
        let cache = home.appending(path: "Library/Caches/\(Self.bundleID)")
        let agent = home.appending(path: "Library/LaunchAgents/\(Self.bundleID).agent.plist")

        // Install.
        try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": Self.bundleID, "CFBundleName": "MacCleaner E2E Probe", "CFBundleExecutable": "probe"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        let executable = app.appending(path: "Contents/MacOS/probe")
        try Data("#!/bin/sh\nsleep 600\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: support.appending(path: "state.db"))
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: cache.appending(path: "blob"))
        _ = try ProcessRunner.run("/usr/bin/defaults", ["write", Self.bundleID, "probe", "-int", "1"])
        try fm.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let job: [String: Any] = ["Label": "\(Self.bundleID).agent", "ProgramArguments": [executable.path], "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: agent)
        _ = try ProcessRunner.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agent.path])
        #expect(try ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.bundleID).agent"]).status == 0)

        // Scan.
        let installed = try #require(ApplicationDiscovery.installedApplications().first { $0.bundleIdentifier == Self.bundleID })
        let resources = AppResourcesScanner(dockAppPaths: []).resources(for: installed)
        let paths = Set(resources.map(\.path))
        let preferences = home.appending(path: "Library/Preferences/\(Self.bundleID).plist").standardizedFileURL.path
        for expected in [app, support, cache, agent].map(\.standardizedFileURL.path) + [preferences] {
            #expect(paths.contains(expected), "missing \(expected)")
        }

        // Uninstall.
        let results = await Uninstaller().remove(resources)
        let failures = results.filter { !$0.succeeded }.map { "\($0.resource.path): \($0.error ?? "")" }
        #expect(failures.isEmpty, "\(failures)")
        for path in [app, support, cache, agent].map(\.path) + [preferences] {
            #expect(!fm.fileExists(atPath: path), "still present: \(path)")
        }
        #expect(try ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.bundleID).agent"]).status != 0, "agent still loaded")
        #expect(try ProcessRunner.run("/usr/bin/defaults", ["read", Self.bundleID]).status != 0, "defaults domain still present")
    }
}
