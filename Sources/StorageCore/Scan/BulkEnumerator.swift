import Foundation

/// getattrlistbulk 기반 디렉터리 열거 (PLAN §4). 버퍼 256KB.
/// 파싱은 ATTR_CMN_RETURNED_ATTRS가 알려주는 반환 비트 기준.
enum BulkEnumerator {
    static let bufferSize = 256 * 1024

    // attr 상수 (타입 혼용 회피용 리터럴)
    private static let cmnReturned: UInt32 = 0x8000_0000
    private static let cmnName: UInt32 = 0x1
    private static let cmnDevID: UInt32 = 0x2
    private static let cmnObjType: UInt32 = 0x8
    private static let cmnModTime: UInt32 = 0x400
    private static let cmnOwner: UInt32 = 0x8000
    private static let cmnFlags: UInt32 = 0x4_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let fileLinkCount: UInt32 = 0x1
    private static let fileTotalSize: UInt32 = 0x2
    private static let fileAllocSize: UInt32 = 0x4
    private static let sfDataless: UInt32 = 0x4000_0000

    private static func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    static func entries(atPath path: String) throws -> [FileEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0 { throw posix(errno) }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = UInt16(5)
        al.commonattr = cmnReturned | cmnName | cmnDevID | cmnObjType | cmnModTime
            | cmnOwner | cmnFlags | cmnFileID
        al.fileattr = fileLinkCount | fileTotalSize | fileAllocSize

        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buf.deallocate() }

        var result: [FileEntry] = []
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufferSize, UInt64(FSOPT_NOFOLLOW))
            if n < 0 { throw posix(errno) }
            if n == 0 { break }
            var p = UnsafeRawPointer(buf)
            for _ in 0..<Int(n) {
                let length = Int(p.loadUnaligned(as: UInt32.self))
                if let e = parse(p, length: length) { result.append(e) }
                p += length
            }
        }
        return result
    }

    private static func parse(_ start: UnsafeRawPointer, length: Int) -> FileEntry? {
        var p = start + 4
        // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr
        let rCommon = p.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let rFile = p.loadUnaligned(fromByteOffset: 12, as: UInt32.self)
        p += 20

        var name = ""
        var devID: Int32 = 0
        var objType: UInt32 = 0
        var mtime = 0
        var owner: UInt32 = 0
        var flags: UInt32 = 0
        var fileID: UInt64 = 0
        var nlink: UInt32 = 1
        var total: Int64 = 0
        var alloc: Int64 = 0

        if rCommon & cmnName != 0 {
            let off = Int(p.loadUnaligned(as: Int32.self))
            let cstr = (p + off).assumingMemoryBound(to: CChar.self)
            name = String(cString: cstr)
            p += 8
        }
        if rCommon & cmnDevID != 0 { devID = Int32(bitPattern: p.loadUnaligned(as: UInt32.self)); p += 4 }
        if rCommon & cmnObjType != 0 { objType = p.loadUnaligned(as: UInt32.self); p += 4 }
        if rCommon & cmnModTime != 0 { mtime = p.loadUnaligned(as: Int.self); p += 16 }
        if rCommon & cmnOwner != 0 { owner = p.loadUnaligned(as: UInt32.self); p += 4 }
        if rCommon & cmnFlags != 0 { flags = p.loadUnaligned(as: UInt32.self); p += 4 }
        if rCommon & cmnFileID != 0 { fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
        if rFile & fileLinkCount != 0 { nlink = p.loadUnaligned(as: UInt32.self); p += 4 }
        if rFile & fileTotalSize != 0 { total = p.loadUnaligned(as: Int64.self); p += 8 }
        if rFile & fileAllocSize != 0 { alloc = p.loadUnaligned(as: Int64.self); p += 8 }

        if name.isEmpty { return nil }
        let isDir = objType == 2      // VDIR
        let isLink = objType == 5     // VLNK
        let dataless = flags & sfDataless != 0
        return FileEntry(
            name: name, isDirectory: isDir, isSymlink: isLink,
            allocatedSize: dataless ? 0 : alloc, logicalSize: total,
            inode: fileID, devID: devID, linkCount: nlink,
            modified: Date(timeIntervalSince1970: TimeInterval(mtime)),
            isDataless: dataless, ownerUID: owner)
    }
}
