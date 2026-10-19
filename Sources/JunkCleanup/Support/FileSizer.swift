import Darwin
import Foundation

/// On-disk (allocated) size: sums `st_blocks` over an `fts` walk that does not follow symlinks.
/// Hard links and APFS clones are counted every time they appear.
public enum FileSizer {
    public static func allocatedSize(of url: URL) -> Int64 {
        var total: Int64 = 0
        url.path.withCString { path in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
            defer { free(paths[0]) }
            guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return }
            defer { fts_close(fts) }
            while let entry = fts_read(fts) {
                if Task.isCancelled { return }
                switch Int32(entry.pointee.fts_info) {
                case FTS_F, FTS_SL, FTS_SLNONE, FTS_DP, FTS_DEFAULT:
                    if let stat = entry.pointee.fts_statp {
                        total += Int64(stat.pointee.st_blocks) * 512
                    }
                default:
                    break
                }
            }
        }
        return total
    }
}
