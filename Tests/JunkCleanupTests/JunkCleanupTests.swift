import Foundation
import Testing
@testable import JunkCleanup

/// Builds a throwaway fake home folder so scanners run against known files only.
private final class FakeHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "maccleaner-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var context: ScanContext {
        ScanContext(paths: JunkPaths(home: root, darwinUserCacheDirectory: nil, temporaryDirectory: root.appending(path: "tmp")), ignore: IgnoreSnapshot())
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 20_000, contents: Data? = nil) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (contents ?? Data(repeating: 0x41, count: bytes)).write(to: url)
        return url
    }
}

@Suite struct CachesTests {
    @Test func groupsCacheChildrenByOwnerAndSkipsEmptyOnes() async throws {
        let home = try FakeHome()
        try home.file("Library/Caches/com.example.App/blob")
        try home.file("Library/Caches/com.example.Other/data")
        try FileManager.default.createDirectory(at: home.root.appending(path: "Library/Caches/com.example.Empty"), withIntermediateDirectories: true)
        try home.file("Library/Caches/.DS_Store")
        try home.file("Library/Containers/com.example.Sandboxed/Data/Library/Caches/thing")

        let subgroups = try await UserCachesScanTask().scan(home.context)
        let owners = Set(subgroups.map(\.id))
        #expect(owners == ["com.example.App", "com.example.Other", "com.example.Sandboxed"])
        #expect(subgroups.allSatisfy { $0.items.allSatisfy(\.isAutoSelected) })
    }

    @Test func gradleIsShownButNotSelected() async throws {
        let home = try FakeHome()
        try home.file(".gradle/caches/modules-2/file.bin")
        let gradle = try #require(try await UserCachesScanTask().scan(home.context).first { $0.id == "Gradle" })
        #expect(gradle.items.allSatisfy { !$0.isAutoSelected })
    }

    @Test func ignoreListHidesEntries() async throws {
        let home = try FakeHome()
        let ignored = try home.file("Library/Caches/com.example.Keep/blob")
        var context = home.context
        context.ignore = IgnoreSnapshot(entries: [ignored.deletingLastPathComponent().path])
        #expect(try await UserCachesScanTask().scan(context).isEmpty)
    }
}

@Suite struct LogsTests {
    @Test func skipsSmallLogsAndKeepsFoldersWithLargeFiles() async throws {
        let home = try FakeHome()
        try home.file("Library/Logs/big.log", bytes: 20_000)
        try home.file("Library/Logs/tiny.log", bytes: 100)
        try home.file("Library/Logs/SomeApp/session.log", bytes: 30_000)
        try home.file("Library/Logs/SmallApp/session.log", bytes: 50)

        let names = try await UserLogsScanTask().scan(home.context).flatMap(\.items).map(\.name)
        #expect(Set(names) == ["big", "SomeApp"])
    }

    @Test func truncatesLogFilesAndDeletesOthers() throws {
        let home = try FakeHome()
        let log = try home.file("Library/Logs/app.log")
        let folder = try home.file("Library/Logs/Folder/x.log").deletingLastPathComponent()

        try JunkCleaner.perform(.truncateOrDelete(log))
        try JunkCleaner.perform(.truncateOrDelete(folder))
        #expect(FileManager.default.fileExists(atPath: log.path))
        #expect((try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? Int) == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

@Suite struct PreferencesTests {
    @Test func onlyUnparseableNonEmptyPlistsAreBroken() throws {
        let home = try FakeHome()
        let broken = try home.file("Library/Preferences/com.example.broken.plist", contents: Data("not a plist <<<".utf8))
        let empty = try home.file("Library/Preferences/com.example.empty.plist", contents: Data())
        let valid = try home.file("Library/Preferences/com.example.valid.plist", contents: try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0))
        #expect(BrokenPreferencesScanTask.isBroken(broken))
        #expect(!BrokenPreferencesScanTask.isBroken(empty))
        #expect(!BrokenPreferencesScanTask.isBroken(valid))
    }
}

@Suite struct LaunchAgentTests {
    @Test func agentIsBrokenOnlyWhenItsProgramIsMissing() {
        #expect(BrokenLaunchAgentsScanTask.isBroken(nil, helperNames: []))
        #expect(BrokenLaunchAgentsScanTask.isBroken([:], helperNames: []))
        #expect(!BrokenLaunchAgentsScanTask.isBroken(["Program": "/bin/ls"], helperNames: []))
        #expect(BrokenLaunchAgentsScanTask.isBroken(["ProgramArguments": ["/usr/bin/definitely-missing-tool"]], helperNames: []))
        #expect(!BrokenLaunchAgentsScanTask.isBroken(["Program": "/usr/bin/definitely-missing-tool"], helperNames: ["definitely-missing-tool"]))
        #expect(!BrokenLaunchAgentsScanTask.isBroken(["Program": "ls", "WorkingDirectory": "/bin"], helperNames: []))
    }
}

@Suite struct XcodeTests {
    @Test func derivedDataNamesAndSelection() async throws {
        let home = try FakeHome()
        try home.file("Library/Developer/Xcode/DerivedData/MyApp-abcdefghij/Build/x")
        try home.file("Library/Developer/Xcode/DerivedData/ModuleCache.noindex/y")
        try home.file("Library/Developer/Xcode/DerivedData/ModuleCache/z")

        let task = try #require(XcodeJunkScanTasks.all.first { $0.identifier == "derivedData" })
        let items = try await task.scan(home.context).flatMap(\.items)
        #expect(Set(items.map(\.name)) == ["MyApp", "ModuleCache.noindex"])
        #expect(items.first { $0.name == "MyApp" }?.isAutoSelected == true)
        #expect(items.first { $0.name == "ModuleCache.noindex" }?.isAutoSelected == false)
    }

    @Test func runtimeNamesAreReadable() {
        #expect(XcodeSimulatorsScanTask.readableRuntime("com.apple.CoreSimulator.SimRuntime.iOS-17-0") == "iOS 17.0")
        #expect(XcodeSimulatorsScanTask.readableRuntime("com.apple.CoreSimulator.SimRuntime.watchOS-10-2") == "watchOS 10.2")
    }
}

@Suite struct DocumentVersionTests {
    @Test func keepsNewestOldestAndOnePerBurst() {
        let now = Date()
        let hours: [Double] = [0, 1, 2, 10, 11, 30] // newest first, hours ago
        let dates = hours.map { now.addingTimeInterval(-$0 * 3600) }
        // 1h and 2h are within 4h of a newer one; 10h is 8h from 2h (kept); 11h within 4h of 10h; 30h is the oldest.
        #expect(DocumentVersionsScanTask.selection(for: dates) == [1, 2, 4])
        #expect(DocumentVersionsScanTask.selection(for: Array(dates.prefix(2))).isEmpty)
    }
}

@Suite struct LanguageTests {
    @Test func canonicalisesLegacyNames() {
        #expect(ApplicationLanguagesScanTask.canonical("English") == "en")
        #expect(ApplicationLanguagesScanTask.canonical("pt-BR") == "pt")
        #expect(ApplicationLanguagesScanTask.canonical("jp") == "ja")
    }

    @Test func removesOnlyStringsOnlyLprojsWhenAKeptLanguageRemains() throws {
        let home = try FakeHome()
        try home.file("Fake.app/Contents/Resources/en.lproj/Localizable.strings")
        try home.file("Fake.app/Contents/Resources/fr.lproj/Localizable.strings")
        try home.file("Fake.app/Contents/Resources/de.lproj/Main.nib")
        try home.file("Other.app/Contents/Resources/fr.lproj/Localizable.strings")

        let kept = ApplicationLanguagesScanTask.keptLanguages(preferred: ["en-US"])
        let fake = ApplicationLanguagesScanTask.removableLocalizations(in: home.root.appending(path: "Fake.app"), kept: kept)
        #expect(Array(fake.keys) == ["fr"])
        let other = ApplicationLanguagesScanTask.removableLocalizations(in: home.root.appending(path: "Other.app"), kept: kept)
        #expect(other.isEmpty) // no kept language would remain
    }

    @Test func sealedLprojIsNeverRemoved() throws {
        let home = try FakeHome()
        try home.file("Fake.app/Contents/Resources/en.lproj/Localizable.strings")
        try home.file("Fake.app/Contents/Resources/fr.lproj/Localizable.strings")
        let seal: [String: Any] = ["files2": ["Resources/fr.lproj/Localizable.strings": ["hash2": Data()]]]
        try home.file("Fake.app/Contents/_CodeSignature/CodeResources", contents: try PropertyListSerialization.data(fromPropertyList: seal, format: .xml, options: 0))

        let kept = ApplicationLanguagesScanTask.keptLanguages(preferred: ["en"])
        #expect(ApplicationLanguagesScanTask.removableLocalizations(in: home.root.appending(path: "Fake.app"), kept: kept).isEmpty)
    }
}

@Suite struct MachOTests {
    @Test func readsSlicesOfAUniversalSystemBinary() throws {
        // /usr/bin/lipo itself ships as a universal binary on current macOS.
        guard let slices = MachOFat.slices(of: URL(fileURLWithPath: "/usr/bin/lipo")) else { return }
        #expect(slices.count >= 2)
        #expect(slices.allSatisfy { $0.size > 0 })
    }

    @Test func thinningKeepsOnlyTheNativeSliceAndLeavesNoTempFiles() throws {
        let home = try FakeHome()
        let binary = home.root.appending(path: "Tool.app/Contents/MacOS/tool")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/lipo"), to: binary)
        guard let before = MachOFat.slices(of: binary), before.count > 1 else { return }

        try JunkCleaner.perform(.thinBinary(binary, keepArchitecture: before[0].name))
        #expect(MachOFat.slices(of: binary)?.map(\.name) == [before[0].name])
        #expect(try FileManager.default.contentsOfDirectory(atPath: binary.deletingLastPathComponent().path) == ["tool"])
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
    }

    @Test func thinFileIsNotFat() throws {
        let home = try FakeHome()
        #expect(MachOFat.slices(of: try home.file("plain.bin")) == nil)
    }
}

@Suite struct EngineTests {
    private struct SlowTask: JunkScanTask {
        let identifier = "slow"
        let title = "Slow"
        let group = JunkGroupID.userCaches
        var timeout: Duration { .milliseconds(100) }
        func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
            try await Task.sleep(for: .seconds(10))
            return []
        }
    }

    private struct FixedTask: JunkScanTask {
        let identifier: String
        let title: String
        let group: JunkGroupID
        func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
            [JunkSubgroup(id: identifier, title: title, items: [JunkItem(name: identifier, url: nil, size: 10, isAutoSelected: true, action: .delete(URL(fileURLWithPath: "/nonexistent/\(identifier)")))])]
        }
    }

    @Test func timeoutsBecomeFailuresAndResultsMergeByGroup() async throws {
        let home = try FakeHome()
        let scanner = JunkScanner(tasks: [
            FixedTask(identifier: "a", title: "A", group: .userLogs),
            SlowTask(),
            FixedTask(identifier: "b", title: "B", group: .userLogs),
        ])
        let result = await scanner.scan(context: home.context)
        #expect(result.groups.map(\.id) == [.userLogs])
        #expect(result.groups[0].subgroups.map(\.id) == ["a", "b"])
        #expect(result.failures.keys.contains("Slow"))
    }

    @Test func cleanerReportsPerItemOutcome() async throws {
        let home = try FakeHome()
        let file = try home.file("junk.bin")
        let ok = JunkItem(name: "ok", url: file, size: 1, isAutoSelected: true, action: .delete(file))
        let bad = JunkItem(name: "bad", url: nil, size: 1, isAutoSelected: true, action: .removeFileVersion(document: file, modificationDate: .distantPast))
        let report = await JunkCleaner().clean([ok, bad])
        #expect(report.outcome == .partialSuccess)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(report.failures.map(\.item.name) == ["bad"])
    }
}

@Suite struct PermissionsTests {
    @Test func probesMissingAndUnreadablePathsAsNoAccess() {
        #expect(!Permissions.canRead("/nonexistent/\(UUID().uuidString)"))
        #expect(Permissions.canRead("/usr/bin"))
        #expect(Permissions.canRead("/etc/hosts"))
    }

    @Test func probeSetCoversMoreThanTheMovedUserDatabase() {
        // macOS 27 dropped the per-user TCC.db; detection must not depend on it alone.
        #expect(Permissions.probePaths.count > 2)
        #expect(Permissions.probePaths.contains("/Library/Application Support/com.apple.TCC/TCC.db"))
    }
}
