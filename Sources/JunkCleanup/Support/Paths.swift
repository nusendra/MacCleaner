import Darwin
import Foundation

/// Well-known locations. `home` is the real home folder even if the process is sandboxed.
public struct JunkPaths: Sendable {
    public var home: URL
    public var darwinUserCacheDirectory: URL?
    public var temporaryDirectory: URL

    public init(home: URL, darwinUserCacheDirectory: URL?, temporaryDirectory: URL) {
        self.home = home
        self.darwinUserCacheDirectory = darwinUserCacheDirectory
        self.temporaryDirectory = temporaryDirectory
    }

    public static var current: JunkPaths {
        JunkPaths(
            home: realHome(),
            darwinUserCacheDirectory: confstrPath(_CS_DARWIN_USER_CACHE_DIR),
            temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        )
    }

    public var library: URL { home.appending(path: "Library", directoryHint: .isDirectory) }
    public var userCaches: URL { library.appending(path: "Caches") }
    public var userLogs: URL { library.appending(path: "Logs") }
    public var userPreferences: URL { library.appending(path: "Preferences") }
    public var containers: URL { library.appending(path: "Containers") }
    public var applicationSupport: URL { library.appending(path: "Application Support") }
    public var xcode: URL { library.appending(path: "Developer/Xcode") }
    public var coreSimulator: URL { library.appending(path: "Developer/CoreSimulator") }

    private static func realHome() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static func confstrPath(_ name: Int32) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
