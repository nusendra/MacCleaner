import Foundation
import MachO

/// Executables inside apps that carry code for CPU architectures this Mac never runs.
struct UniversalBinariesScanTask: JunkScanTask {
    let identifier = "universalBinaries"
    let title = "Universal binaries"
    let group = JunkGroupID.universalBinaries

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let rosettaForced = Self.appsForcedToRosetta(home: context.paths.home)
        let ownBundleID = Bundle.main.bundleIdentifier?.lowercased()
        var subgroups: [JunkSubgroup] = []

        for app in InstalledApps.all(home: context.paths.home) {
            try Task.checkCancellation()
            let bundleID = app.bundleIdentifier?.lowercased()
            guard context.canRemove(app.url), !context.ignore.isIgnored(app.url),
                  !(app.bundleIdentifier.map(context.ignore.isIgnored(name:)) ?? false),
                  bundleID == nil || (bundleID != ownBundleID && !rosettaForced.contains(bundleID!)),
                  (try? app.url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable != true,
                  let executable = app.executableURL,
                  let keep = MachOFat.nativeArchitecture(of: executable)
            else { continue }

            let sealed = Self.sealedFiles(in: app.url)
            var items: [JunkItem] = []
            for binary in Self.executables(in: app.url) where !sealed.contains(binary.standardizedFileURL.path) {
                guard context.canRemove(binary), let slices = MachOFat.slices(of: binary) else { continue }
                guard slices.contains(where: { $0.name == keep }) else {
                    items = []
                    break // a binary without a native slice means we misjudged the app; leave it alone
                }
                let removable = slices.filter { $0.name != keep }.reduce(Int64(0)) { $0 + $1.size }
                guard removable > 0 else { continue }
                items.append(JunkItem(
                    name: binary.lastPathComponent,
                    detail: slices.filter { $0.name != keep }.map(\.name).joined(separator: ", "),
                    url: binary,
                    size: removable,
                    isAutoSelected: false,
                    action: .thinBinary(binary, keepArchitecture: keep),
                    quitBeforeCleaning: app.bundleIdentifier.map { [$0] } ?? []
                ))
            }
            if !items.isEmpty {
                subgroups.append(JunkSubgroup(id: "universal.\(app.url.path)", title: app.name, bundleIdentifier: app.bundleIdentifier, items: items))
            }
        }
        return subgroups.sorted { $0.size > $1.size }
    }

    /// Extension-less executable files that are not symlinks, skipping inside lproj folders.
    static func executables(in bundle: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isExecutableKey]
        let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys)
        var result: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "lproj" {
                enumerator?.skipDescendants()
                continue
            }
            guard url.pathExtension.isEmpty, !["PkgInfo", "CodeResources", ".DS_Store"].contains(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isDirectory != true, values.isExecutable == true
            else { continue }
            result.append(url)
        }
        return result
    }

    /// Absolute paths of files sealed non-optionally by any CodeResources in the bundle; those are never thinned.
    static func sealedFiles(in bundle: URL) -> Set<String> {
        var sealed: Set<String> = []
        let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent == "CodeResources", url.deletingLastPathComponent().lastPathComponent == "_CodeSignature",
                  let plist = NSDictionary(contentsOf: url) as? [String: Any]
            else { continue }
            let root = url.deletingLastPathComponent().deletingLastPathComponent()
            for key in ["files", "files2"] {
                for (path, value) in (plist[key] as? [String: Any]) ?? [:] where ((value as? [String: Any])?["optional"] as? Bool) != true {
                    sealed.insert(root.appending(path: path).standardizedFileURL.path)
                }
            }
        }
        return sealed
    }

    /// Bundle ids the user set to "Open using Rosetta" (or pinned to arm64) in Finder's Get Info.
    static func appsForcedToRosetta(home: URL) -> Set<String> {
        let plist = home.appending(path: "Library/Preferences/com.apple.LaunchServices/com.apple.LaunchServices.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return [] }
        return Set(["Architectures for arm64", "Architectures for x86_64"].flatMap { key in
            ((info[key] as? [String: Any]) ?? [:]).keys.map { $0.lowercased() }
        })
    }
}

/// Minimal fat (universal) Mach-O header reader.
enum MachOFat {
    struct Slice: Equatable {
        var name: String
        var size: Int64
    }

    /// Slices of a fat binary, or nil if the file is not a fat Mach-O.
    static func slices(of url: URL) -> [Slice]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
        let magic = header.bigEndianUInt32(at: 0)
        guard magic == FAT_MAGIC || magic == FAT_MAGIC_64 else { return nil }
        let count = Int(header.bigEndianUInt32(at: 4))
        guard count > 0, count < 32 else { return nil }
        let entrySize = magic == FAT_MAGIC_64 ? 32 : 20
        guard let table = try? handle.read(upToCount: entrySize * count), table.count == entrySize * count else { return nil }
        return (0..<count).map { index in
            let base = index * entrySize
            let cpuType = Int32(bitPattern: table.bigEndianUInt32(at: base))
            let cpuSubtype = Int32(bitPattern: table.bigEndianUInt32(at: base + 4))
            let size = magic == FAT_MAGIC_64
                ? Int64(table.bigEndianUInt64(at: base + 16))
                : Int64(table.bigEndianUInt32(at: base + 12))
            return Slice(name: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype), size: size)
        }
    }

    /// The slice this Mac executes: arm64 on Apple silicon (even under Rosetta), otherwise x86_64.
    /// Returns nil for thin binaries and for fat binaries that lack it.
    static func nativeArchitecture(of executable: URL) -> String? {
        let preferred = isAppleSilicon ? "arm64" : "x86_64"
        guard let slices = slices(of: executable), slices.count > 1, slices.contains(where: { $0.name == preferred }) else { return nil }
        return preferred
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0, value == 1 { return true }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Only plain arm64 and x86_64 are recognised; arm64e, x86_64h, i386 and ppc are never kept or matched.
    static func architectureName(cpuType: Int32, cpuSubtype: Int32) -> String {
        let subtype = cpuSubtype & 0x00FF_FFFF
        switch (cpuType, subtype) {
        case (CPU_TYPE_ARM64, 0): return "arm64"
        case (CPU_TYPE_ARM64, 2): return "arm64e"
        case (CPU_TYPE_X86_64, 3): return "x86_64"
        case (CPU_TYPE_X86_64, 8): return "x86_64h"
        case (CPU_TYPE_I386, _): return "i386"
        default: return "cpu\(cpuType)"
        }
    }
}

private extension Data {
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        self[startIndex + offset..<startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func bigEndianUInt64(at offset: Int) -> UInt64 {
        self[startIndex + offset..<startIndex + offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
