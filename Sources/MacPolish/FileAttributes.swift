import Darwin
import Foundation

/// Size facts for one file system entry, read with `getattrlist` or `getattrlistbulk`.
struct FileAttributes: Sendable, Equatable {
    enum Kind: Sendable, Equatable { case file, folder, symlink, other }

    var name: String
    var kind: Kind
    var device: Int32
    var isMountPoint: Bool
    var modified: Date?
    var linkCount: UInt32
    var allocated: Int64
    /// Blocks only this file uses (APFS). nil when the file system does not report it.
    var privateSize: Int64?
    /// Number of files sharing this file's data (APFS clones); 0 or 1 when not shared.
    var cloneRefCount: UInt32
    /// Error macOS reported for this entry inside a directory listing (for example EPERM), or 0.
    var error: Int32

    /// This path's share of the disk blocks. Unchanged APFS clones share one data stream and hard links
    /// share one file, so each path carries an equal part; the parts add up to the real space used.
    var attributedBytes: Int64 {
        allocated / Int64(max(cloneRefCount, 1)) / Int64(max(linkCount, 1))
    }

    /// Blocks a clone that was later modified may still share with another file. APFS does not say with
    /// which file, so they are counted here in full and may also be counted there.
    var uncertainBytes: Int64 {
        guard kind == .file, cloneRefCount <= 1, let privateSize, privateSize >= 0, privateSize < allocated else { return 0 }
        return (allocated - privateSize) / Int64(max(linkCount, 1))
    }

    /// Reads one path without following a final symbolic link. nil when the path cannot be examined.
    static func read(path: String) -> FileAttributes? {
        var request = AttributeRequest.list(bulk: false)
        let size = 4_096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        let options = UInt32(FSOPT_NOFOLLOW) | UInt32(FSOPT_ATTR_CMN_EXTENDED)
        guard getattrlist(path, &request, buffer, size, options) == 0 else { return nil }
        return AttributeRequest.parse(UnsafeRawPointer(buffer))
    }
}

/// Lists a directory with `getattrlistbulk`: one system call returns the attributes of many entries.
enum BulkDirectoryReader {
    struct Listing: Sendable {
        var entries: [FileAttributes]
        /// errno when the directory could not be opened or read to the end.
        var error: Int32?
    }

    static func entries(of path: String) -> Listing {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return Listing(entries: [], error: errno) }
        defer { close(descriptor) }

        var request = AttributeRequest.list(bulk: true)
        let size = 256 * 1_024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [FileAttributes] = []
        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, size, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count < 0 { return Listing(entries: entries, error: errno) }
            if count == 0 { return Listing(entries: entries, error: nil) }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = entry.loadUnaligned(as: UInt32.self)
                entries.append(AttributeRequest.parse(entry))
                entry += Int(length)
            }
        }
    }
}

/// The attribute set both readers request, and the parser for one returned entry.
private enum AttributeRequest {
    static func group<T: BinaryInteger>(_ value: T) -> attrgroup_t { attrgroup_t(truncatingIfNeeded: value) }

    static func list(bulk: Bool) -> attrlist {
        var common = group(ATTR_CMN_RETURNED_ATTRS) | group(ATTR_CMN_NAME) | group(ATTR_CMN_DEVID)
            | group(ATTR_CMN_OBJTYPE) | group(ATTR_CMN_MODTIME)
        // ATTR_CMN_ERROR is only valid for directory listings.
        if bulk { common |= group(ATTR_CMN_ERROR) }
        return attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: common, volattr: 0,
                        dirattr: group(ATTR_DIR_MOUNTSTATUS),
                        fileattr: group(ATTR_FILE_LINKCOUNT) | group(ATTR_FILE_ALLOCSIZE),
                        // With FSOPT_ATTR_CMN_EXTENDED, forkattr carries the extended common attributes.
                        forkattr: group(ATTR_CMNEXT_PRIVATESIZE) | group(ATTR_CMNEXT_CLONE_REFCNT))
    }

    /// Reads the fields in the order the kernel packs them: common, directory, file, then extended.
    /// Only attributes marked in the returned set are present; values are 4-byte aligned.
    static func parse(_ start: UnsafeRawPointer) -> FileAttributes {
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        func has(_ set: attrgroup_t, _ bit: some BinaryInteger) -> Bool { set & group(bit) != 0 }
        func take<T>(_ type: T.Type) -> T {
            let value = field.loadUnaligned(as: T.self)
            field += MemoryLayout<T>.size
            return value
        }

        var result = FileAttributes(name: "", kind: .other, device: 0, isMountPoint: false, modified: nil,
                                    linkCount: 1, allocated: 0, privateSize: nil, cloneRefCount: 0, error: 0)
        if has(returned.commonattr, ATTR_CMN_ERROR) { result.error = Int32(bitPattern: take(UInt32.self)) }
        if has(returned.commonattr, ATTR_CMN_NAME) {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let bytes = UnsafeRawBufferPointer(start: field + Int(reference.attr_dataoffset),
                                               count: max(0, Int(reference.attr_length) - 1))
            result.name = String(decoding: bytes, as: UTF8.self)
            field += MemoryLayout<attrreference_t>.size
        }
        if has(returned.commonattr, ATTR_CMN_DEVID) { result.device = take(Int32.self) }
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) {
            switch take(UInt32.self) {
            case UInt32(VREG.rawValue): result.kind = .file
            case UInt32(VDIR.rawValue): result.kind = .folder
            case UInt32(VLNK.rawValue): result.kind = .symlink
            default: result.kind = .other
            }
        }
        if has(returned.commonattr, ATTR_CMN_MODTIME) {
            let time = take(timespec.self)
            result.modified = Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
        }
        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
            result.isMountPoint = take(UInt32.self) & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
        }
        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { result.linkCount = take(UInt32.self) }
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { result.allocated = max(0, take(Int64.self)) }
        if has(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE) { result.privateSize = take(Int64.self) }
        if has(returned.forkattr, ATTR_CMNEXT_CLONE_REFCNT) { result.cloneRefCount = take(UInt32.self) }
        return result
    }
}
