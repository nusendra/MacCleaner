import Foundation
import Testing
@testable import AppUninstaller
@testable import JunkCleanup

@Suite struct ResourceMatcherTests {
    let foo = ResourceMatcher(bundleID: "com.foo.app", name: "Foo Writer")

    @Test func bundleIDMatchesOnWordBoundariesOnly() {
        #expect(foo.matches(entryName: "com.foo.app", isDirectory: true))
        #expect(foo.matches(entryName: "com.foo.app.helper", isDirectory: true))
        #expect(foo.matches(entryName: "group.com.foo.app", isDirectory: true))
        #expect(foo.matches(entryName: "com.foo.app.plist", isDirectory: false))
        #expect(!foo.matches(entryName: "com.foo.application", isDirectory: true))
    }

    @Test func nameMatchesWholeWordsInAnyOrder() {
        #expect(foo.matches(entryName: "Foo Writer", isDirectory: true))
        #expect(foo.matches(entryName: "Writer Foo Backups", isDirectory: true))
        #expect(!foo.matches(entryName: "FooWriter", isDirectory: true))
        #expect(!foo.matches(entryName: "Foo", isDirectory: true))
    }

    @Test func otherMajorVersionsAreNotClaimed() {
        #expect(!foo.matches(entryName: "Foo Writer 2", isDirectory: true))
        #expect(!foo.matches(entryName: "com.foo.app2", isDirectory: true))
    }

    @Test func sharedAndAppleFoldersAreNeverClaimed() {
        let google = ResourceMatcher(bundleID: "com.google.Chrome", name: "Google")
        #expect(!google.matches(entryName: "Google", isDirectory: true))
        #expect(!foo.matches(entryName: "com.apple.foo.app", isDirectory: true))
    }

    @Test func genericAppNamesOnlyMatchByBundleID() {
        let notes = ResourceMatcher(bundleID: "com.vendor.notes", name: "Notes")
        #expect(!notes.matches(entryName: "Notes", isDirectory: true))
        #expect(notes.matches(entryName: "com.vendor.notes", isDirectory: true))
    }

    @Test func vsCodeStyleBundleNameMatchesItsFolder() {
        let code = ResourceMatcher(bundleID: "com.microsoft.VSCode", name: "Code")
        #expect(code.matches(entryName: "Code", isDirectory: true))
    }

    @Test func preferencesMatchOnComponents() {
        #expect(foo.matchesPreference(fileName: "com.foo.app.plist"))
        #expect(foo.matchesPreference(fileName: "com.foo.app.helper.plist"))
        #expect(foo.matchesPreference(fileName: "TEAM123.com.foo.app.plist"))
        #expect(!foo.matchesPreference(fileName: "com.foo.other.plist"))
    }
}

@Suite struct LeftoversTests {
    @Test func variantsStripTeamGroupAndHelperParts() {
        let variants = LeftoversScanner.variants(of: "abcde12345.com.foo.app.helper")
        #expect(variants.contains("com.foo.app.helper"))
        #expect(variants.contains("com.foo.app"))
        #expect(LeftoversScanner.variants(of: "group.com.foo.app").contains("com.foo.app"))
    }

    @Test func installedMatchingCoversPrefixesAndVersions() {
        let installed: Set = ["net.telestream.screenflow10", "com.foo.app"]
        #expect(LeftoversScanner.belongsToInstalled("com.foo.app.helper", installedIDs: installed))
        #expect(LeftoversScanner.belongsToInstalled("com.foo", installedIDs: installed))
        #expect(LeftoversScanner.belongsToInstalled("net.telestream.screenflow.globallibrary", installedIDs: installed))
        #expect(!LeftoversScanner.belongsToInstalled("com.docker.docker", installedIDs: installed))
    }

    @Test func vendorSharedFilesStayWhileTheVendorHasApps() {
        let installed: Set = ["us.zoom.xos", "com.microsoft.teams2"]
        #expect(LeftoversScanner.isVendorSharedFile("us.zoom.updater.config", installedIDs: installed))
        #expect(LeftoversScanner.isVendorSharedFile("com.microsoft.shared", installedIDs: installed))
        #expect(!LeftoversScanner.isVendorSharedFile("us.zoom.zoomclips", installedIDs: installed))
        #expect(!LeftoversScanner.isVendorSharedFile("com.adobe.crashreporter", installedIDs: installed))
    }

    @Test func helpersFoldIntoTheirApp() {
        let candidates = ["com.foo.app", "com.foo.app.private", "com.foo.app.Extension", "com.bar.tool"].map {
            LeftoversScanner.Candidate(bundleID: $0, name: $0, sourcePath: "/x/\($0)")
        }
        #expect(LeftoversScanner.mergingHelpers(candidates).map(\.bundleID) == ["com.foo.app", "com.bar.tool"])
    }

    @Test func findsPreferenceAndContainerLeftoversButNotSystemOnes() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "mclean-leftovers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let prefs = home.appending(path: "Library/Preferences")
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        for name in ["com.gone.app.plist", "com.apple.finder.plist", "systemgroup.com.apple.x.plist", "com.kept.app.plist", "loginwindow.plist"] {
            try Data("x".utf8).write(to: prefs.appending(path: name))
        }
        let container = home.appending(path: "Library/Containers/com.gone.sandboxed")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let scanner = LeftoversScanner(paths: JunkPaths(home: home, darwinUserCacheDirectory: nil, temporaryDirectory: home), ignore: IgnoreSnapshot())
        let found = scanner.candidates(installedIDs: ["com.kept.app"], isKnownToLaunchServices: { _ in false }).map(\.bundleID)
        #expect(Set(found) == ["com.gone.app", "com.gone.sandboxed"])
    }
}

@Suite struct ResourceScannerTests {
    @Test func collectsMatchingFilesAcrossLibraryFolders() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "mclean-resources-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let files = [
            "Library/Application Support/Foo Writer/data.db",
            "Library/Caches/com.foo.app/blob",
            "Library/Preferences/com.foo.app.plist",
            "Library/Containers/com.foo.app/Data/x",
            "Library/Containers/com.foo.app.share/Data/x",
            "Library/Saved Application State/com.foo.app.savedState/data",
            "Library/Logs/DiagnosticReports/Foo Writer_2026-01-01.ips",
            "Library/Caches/com.other.app/blob",
        ]
        for path in files {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 100).write(to: url)
        }
        let agents = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let job: [String: Any] = ["Label": "com.foo.app.updater", "Program": "/nonexistent"]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: agents.appending(path: "com.foo.app.updater.plist"))

        let scanner = AppResourcesScanner(paths: JunkPaths(home: home, darwinUserCacheDirectory: nil, temporaryDirectory: home.appending(path: "tmp")), ignore: IgnoreSnapshot(), dockAppPaths: [])
        let app = InstalledApplication(leftoverBundleID: "com.foo.app", name: "Foo Writer")
        let found = scanner.resources(for: app)
        let relative = Set(found.map { $0.path.replacingOccurrences(of: home.standardizedFileURL.path + "/", with: "") })
        #expect(relative == [
            "Library/Application Support/Foo Writer",
            "Library/Caches/com.foo.app",
            "Library/Preferences/com.foo.app.plist",
            "Library/Containers/com.foo.app",
            "Library/Containers/com.foo.app.share",
            "Library/Saved Application State/com.foo.app.savedState",
            "Library/Logs/DiagnosticReports/Foo Writer_2026-01-01.ips",
            "Library/LaunchAgents/com.foo.app.updater.plist",
        ])
        let preference = try #require(found.first { $0.group == .preferences })
        guard case .preferences(let url) = preference.removal else { Issue.record("preferences use defaults delete"); return }
        #expect(url.lastPathComponent == "com.foo.app.plist")
        #expect(found.first { $0.group == .loginItems }.map { if case .launchAgent = $0.removal { true } else { false } } == true)
    }

    @Test func packagePathsCollapseToTopLevelBundles() {
        #expect(AppResourcesScanner.topLevelBundle(of: "Applications/Foo.app/Contents/MacOS/foo") == "Applications/Foo.app")
        #expect(AppResourcesScanner.topLevelBundle(of: "usr/local/bin/foo") == "usr/local/bin/foo")
    }
}

@Suite struct UninstallerTests {
    @Test func movesFilesToTheTrashAndRefusesProtectedItems() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "mclean-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "junk.txt")
        try Data("x".utf8).write(to: file)

        let removable = AppResource(path: file.path, group: .caches, size: 1, removal: .trash(file))
        let protected = AppResource(path: "/System/Applications/Notes.app", group: .binaries, size: 1, isRemovable: false, removal: .trash(URL(fileURLWithPath: "/System/Applications/Notes.app")), note: "Protected")
        let results = await Uninstaller().remove([removable, protected])

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(results.first { $0.resource.path == file.path }?.succeeded == true)
        #expect(results.first { $0.resource.isRemovable == false }?.error == "Protected")
        #expect(FileManager.default.fileExists(atPath: "/System/Applications/Notes.app"))
    }

    @Test func launchJobsGoFirstAndTheAppLast() {
        let app = ResourceRemoval.trash(URL(fileURLWithPath: "/Applications/Foo.app"))
        let cache = ResourceRemoval.trash(URL(fileURLWithPath: "/tmp/cache"))
        let agent = ResourceRemoval.launchAgent(URL(fileURLWithPath: "/tmp/a.plist"), label: "a")
        #expect([app, cache, agent].sorted { Uninstaller.priority($0) < Uninstaller.priority($1) } == [agent, cache, app])
    }
}

@Suite struct InstalledApplicationTests {
    @Test func vendorsComeFromBundleIDPrefixes() {
        #expect(AppVendor.forBundleID("com.microsoft.VSCode") == .microsoft)
        #expect(AppVendor.forBundleID("com.google.Chrome") == .google)
        #expect(AppVendor.forBundleID("com.mitchellh.ghostty") == .other)
    }

    @Test func discoversRealApplicationsWithBasicMetadata() throws {
        let apps = ApplicationDiscovery.installedApplications()
        // Safari in /Applications is a symlink into a Cryptex; it must still be discovered.
        let safari = try #require(apps.first { $0.bundleIdentifier == "com.apple.Safari" })
        #expect(safari.isSystem)
        let bundle = try #require(AppResourcesScanner(dockAppPaths: []).resources(for: safari).first { $0.group == .binaries })
        #expect(!bundle.isRemovable)
        let calculator = try #require(apps.first { $0.bundleIdentifier == "com.apple.calculator" })
        #expect(calculator.isSystem)
        #expect(!apps.contains { $0.url?.path.contains(".app/") == true }) // no nested apps
    }
}
