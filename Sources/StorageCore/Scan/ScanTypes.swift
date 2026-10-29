import Foundation

/// 디렉터리 트리 노드 (PLAN §4). 파일 노드는 디렉터리별 상위 200개만 유지되고 나머지는 부모 합계에만 반영.
public struct Node: Sendable, Equatable, Codable {
    public var name: String
    public var isDirectory: Bool
    /// 할당 크기(바이트). 디렉터리는 하위 합계(하드링크 1회 집계 반영).
    public var allocatedSize: Int64
    public var logicalSize: Int64
    public var inode: UInt64
    public var devID: Int32
    public var linkCount: UInt32
    public var modified: Date
    public var isDataless: Bool
    public var ownerUID: UInt32
    public var children: [Node]
    /// 상위 200개 제한으로 노드에서 빠진 파일 수 / 할당 바이트 (부모 합계에는 반영됨).
    public var omittedFileCount: Int = 0
    public var omittedBytes: Int64 = 0

    public init(name: String, isDirectory: Bool, allocatedSize: Int64, logicalSize: Int64,
                inode: UInt64, devID: Int32, linkCount: UInt32 = 1, modified: Date,
                isDataless: Bool = false, ownerUID: UInt32 = 0, children: [Node] = [],
                omittedFileCount: Int = 0, omittedBytes: Int64 = 0) {
        self.omittedFileCount = omittedFileCount; self.omittedBytes = omittedBytes
        self.name = name; self.isDirectory = isDirectory
        self.allocatedSize = allocatedSize; self.logicalSize = logicalSize
        self.inode = inode; self.devID = devID; self.linkCount = linkCount
        self.modified = modified; self.isDataless = isDataless
        self.ownerUID = ownerUID; self.children = children
    }
}

public struct ScanProgress: Sendable, Equatable {
    public var itemCount: Int
    public var bytes: Int64
    public var currentPath: String
    public init(itemCount: Int, bytes: Int64, currentPath: String) {
        self.itemCount = itemCount; self.bytes = bytes; self.currentPath = currentPath
    }
}

public struct ScanResult: Sendable, Equatable, Codable {
    public var rootPath: String
    public var root: Node
    /// EPERM/EACCES 등으로 건너뛴 경로.
    public var skipped: [String]
    public var startedAt: Date
    public var finishedAt: Date
    public init(rootPath: String, root: Node, skipped: [String], startedAt: Date, finishedAt: Date) {
        self.rootPath = rootPath; self.root = root; self.skipped = skipped
        self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}
