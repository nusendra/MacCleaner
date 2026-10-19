import Darwin
import Foundation

public enum Permissions {
    /// Probes a file that only Full Disk Access can open. Unlike touching `~/Downloads` or another app's
    /// container, a failed `open` here never shows a consent prompt, so it is safe to call at any time.
    public static var hasFullDiskAccess: Bool {
        let probe = JunkPaths.current.library.appending(path: "Application Support/com.apple.TCC/TCC.db").path
        let fd = open(probe, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
