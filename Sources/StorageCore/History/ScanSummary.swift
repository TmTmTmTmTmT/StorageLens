import Foundation

/// 스캔 요약 (PLAN §9). 저장·비교 로직은 M2-T2.
public struct ScanSummary: Sendable, Equatable, Codable {
    public struct FolderSize: Sendable, Equatable, Codable {
        public var path: String
        public var allocatedSize: Int64
        public init(path: String, allocatedSize: Int64) { self.path = path; self.allocatedSize = allocatedSize }
    }
    public var scannedAt: Date
    public var rootPath: String
    public var categoryTotals: [String: Int64]
    public var topFolders: [FolderSize]
    /// 파일 스키마 버전. 없으면(구 파일) 1로 간주. 현재보다 큰 파일은 HistoryStore가 건너뛴다(삭제 금지).
    public var schemaVersion: Int?
    public static let currentSchemaVersion = 1
    public init(scannedAt: Date, rootPath: String, categoryTotals: [String: Int64], topFolders: [FolderSize],
                schemaVersion: Int? = ScanSummary.currentSchemaVersion) {
        self.scannedAt = scannedAt; self.rootPath = rootPath
        self.categoryTotals = categoryTotals; self.topFolders = topFolders
        self.schemaVersion = schemaVersion
    }
}
