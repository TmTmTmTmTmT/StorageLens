import Foundation

/// 파일시스템에서 읽은 단일 항목의 속성 (PLAN §4 수집 속성).
public struct FileEntry: Sendable, Equatable, Codable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var allocatedSize: Int64
    public var logicalSize: Int64
    public var inode: UInt64
    public var devID: Int32
    public var linkCount: UInt32
    public var modified: Date
    public var isDataless: Bool
    public var ownerUID: UInt32

    public init(name: String, isDirectory: Bool, isSymlink: Bool = false,
                allocatedSize: Int64, logicalSize: Int64, inode: UInt64, devID: Int32,
                linkCount: UInt32 = 1, modified: Date, isDataless: Bool = false, ownerUID: UInt32 = 0) {
        self.name = name; self.isDirectory = isDirectory; self.isSymlink = isSymlink
        self.allocatedSize = allocatedSize; self.logicalSize = logicalSize
        self.inode = inode; self.devID = devID; self.linkCount = linkCount
        self.modified = modified; self.isDataless = isDataless; self.ownerUID = ownerUID
    }
}
