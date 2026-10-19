import Darwin
import Foundation

/// One directory entry as returned by the kernel.
struct DirectoryEntry {
    enum Kind { case file, directory, symlink, other }
    var name: String
    var kind: Kind
    var flags: UInt32
    /// Allocated (on-disk) bytes; 0 for directories.
    var allocatedSize: Int64
}

/// Reads a whole directory with `getattrlistbulk`: names, types, BSD flags and allocated sizes come back in
/// batches from one system call, instead of a `readdir` plus an `lstat` per entry.
enum DirectoryReader {
    static func entries(at path: String) -> [DirectoryEntry]? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
        request.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var result: [DirectoryEntry] = []

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 { return result.isEmpty ? nil : result }
            if count == 0 { return result }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.load(as: UInt32.self))
                if let parsed = parse(entry) { result.append(parsed) }
                entry += length
            }
        }
    }

    /// Layout: length, returned-attrs set, then the requested attributes in fixed order (name ref, objtype, flags, allocsize).
    private static func parse(_ record: UnsafeMutableRawPointer) -> DirectoryEntry? {
        var cursor = record + MemoryLayout<UInt32>.size
        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
        cursor += MemoryLayout<attribute_set_t>.size

        var name = ""
        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
            let reference = cursor.loadUnaligned(as: attrreference_t.self)
            name = String(cString: (cursor + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
            cursor += MemoryLayout<attrreference_t>.size
        }
        guard !name.isEmpty else { return nil }

        var type: fsobj_type_t = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            type = cursor.loadUnaligned(as: fsobj_type_t.self)
            cursor += MemoryLayout<fsobj_type_t>.size
        }
        var flags: UInt32 = 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            flags = cursor.loadUnaligned(as: UInt32.self)
            cursor += MemoryLayout<UInt32>.size
        }
        var size: Int64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            size = cursor.loadUnaligned(as: off_t.self)
        }

        let kind: DirectoryEntry.Kind
        switch Int(type) {
        case Int(VREG.rawValue): kind = .file
        case Int(VDIR.rawValue): kind = .directory
        case Int(VLNK.rawValue): kind = .symlink
        default: kind = .other
        }
        return DirectoryEntry(name: name, kind: kind, flags: flags, allocatedSize: kind == .directory ? 0 : size)
    }
}
