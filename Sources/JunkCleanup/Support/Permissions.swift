import Darwin
import Foundation

public enum Permissions {
    /// Locations only Full Disk Access can read. Without it they fail with EPERM and never show a consent
    /// prompt (unlike Desktop, Documents or Downloads), so probing them is always safe.
    /// Several are tried because none exists everywhere: macOS 27 no longer has a per-user TCC.db, and Mail,
    /// Messages or Safari data may be missing if those apps were never used.
    static var probePaths: [String] {
        let home = JunkPaths.current.home.path
        return [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari",
            home + "/Library/Mail",
            home + "/Library/Messages",
            home + "/Library/Containers/com.apple.Safari",
        ]
    }

    public static var hasFullDiskAccess: Bool {
        probePaths.contains(where: canRead)
    }

    /// Opens the file or lists the folder without following it anywhere else.
    static func canRead(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard let dir = opendir(path) else { return false }
            defer { closedir(dir) }
            return readdir(dir) != nil
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
