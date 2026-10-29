import Foundation

/// 파일시스템 접근 추상화. 테스트에서 가짜 구현을 주입한다.
public protocol FileSystem: Sendable {
    /// 디렉터리 직속 항목의 속성(심볼릭 링크는 따라가지 않음). EPERM/EACCES 등은 throw.
    func entries(in directory: URL) throws -> [FileEntry]
    /// lstat 기준 단일 항목 속성.
    func attributes(at url: URL) throws -> FileEntry
    func fileExists(at url: URL) -> Bool
    /// 심볼릭 링크를 모두 해석한 경로.
    func realPath(of url: URL) throws -> URL
    /// `FileManager.trashItem` 대응. 휴지통 내 결과 경로 반환.
    func trashItem(at url: URL) throws -> URL?
    func moveItem(at source: URL, to destination: URL) throws
    /// `FileManager.evictUbiquitousItem` 대응 (iCloud 로컬 사본만 비움).
    func evictUbiquitousItem(at url: URL) throws
}

/// 실제 파일시스템 구현. (M1-T1에서 getattrlistbulk 기반 열거로 확장될 수 있음)
public struct SystemFileSystem: FileSystem {
    public init() {}

    public func entries(in directory: URL) throws -> [FileEntry] {
        do {
            return try BulkEnumerator.entries(atPath: directory.path)
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(ENOTSUP) {
            // getattrlistbulk 미지원 파일시스템: lstat 폴백
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try names.map { try attributes(at: directory.appendingPathComponent($0)) }
    }

    public func attributes(at url: URL) throws -> FileEntry {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let mode = st.st_mode & S_IFMT
        let dataless = (st.st_flags & UInt32(SF_DATALESS)) != 0
        return FileEntry(
            name: url.lastPathComponent,
            isDirectory: mode == S_IFDIR,
            isSymlink: mode == S_IFLNK,
            allocatedSize: dataless ? 0 : Int64(st.st_blocks) * 512,
            logicalSize: Int64(st.st_size),
            inode: UInt64(st.st_ino),
            devID: Int32(st.st_dev),
            linkCount: UInt32(st.st_nlink),
            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
            isDataless: dataless,
            ownerUID: UInt32(st.st_uid))
    }

    public func fileExists(at url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public func realPath(of url: URL) throws -> URL {
        guard let p = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p))
    }

    public func trashItem(at url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func evictUbiquitousItem(at url: URL) throws {
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
