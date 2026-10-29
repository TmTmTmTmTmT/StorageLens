import Foundation
import Synchronization

public extension ScanSummary {
    /// 깊이 3까지(루트=0) 폴더 중 allocatedSize 상위 200개 + categoryTotals
    static func make(from result: ScanResult, categoryTotals: [String: Int64], scannedAt: Date) -> ScanSummary {
        var folders: [ScanSummary.FolderSize] = []
        func walk(_ node: Node, path: String, depth: Int) {
            guard node.isDirectory else { return }
            folders.append(ScanSummary.FolderSize(path: path, allocatedSize: node.allocatedSize))
            guard depth < 3 else { return }
            for child in node.children where child.isDirectory {
                let childPath = path == "/" ? "/" + child.name : path + "/" + child.name
                walk(child, path: childPath, depth: depth + 1)
            }
        }
        walk(result.root, path: result.rootPath, depth: 0)
        folders.sort { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.path < $1.path }
        return ScanSummary(scannedAt: scannedAt, rootPath: result.rootPath,
                           categoryTotals: categoryTotals, topFolders: Array(folders.prefix(200)))
    }
}

public struct SummaryChange: Sendable, Equatable {
    public let path: String
    public let previous: Int64
    public let current: Int64
    public var delta: Int64 { current - previous }
    public init(path: String, previous: Int64, current: Int64) {
        self.path = path; self.previous = previous; self.current = current
    }
}

public final class HistoryStore: Sendable {
    public static let maxEntries = 30
    /// 손상 파일을 옮겨 두는 하위 폴더 이름.
    public static let corruptDirectoryName = "corrupt"
    private let directory: URL
    private let corruptNames = Mutex<Set<String>>([])
    private let futureNames = Mutex<Set<String>>([])

    public init(directory: URL) { self.directory = directory }

    /// 이 인스턴스가 로드 중 발견해 격리한(격리 실패 포함) 손상 파일 수.
    public var corruptFileCount: Int { corruptNames.withLock { $0.count } }
    /// 이 인스턴스가 로드 중 건너뛴 미래 schemaVersion 파일 수 (삭제·이동하지 않음).
    public var skippedFutureVersionCount: Int { futureNames.withLock { $0.count } }
    /// 디스크의 corrupt/ 폴더에 쌓여 있는 파일 수 (이전 실행분 포함).
    public var quarantinedFileCount: Int {
        let dir = directory.appendingPathComponent(Self.corruptDirectoryName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
    }

    private static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss.SSS'Z'"
        return f.string(from: date) + ".json"
    }

    public func save(_ summary: ScanSummary) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(summary)
        let url = directory.appendingPathComponent(Self.fileName(for: summary.scannedAt))
        try data.write(to: url, options: .atomic)
        // 최근 30개만 유지 (손상·미래 버전 파일은 loadEntries에서 제외되므로 한도에 포함되지 않음)
        let entries = loadEntries().sorted { $0.summary.scannedAt > $1.summary.scannedAt }
        for e in entries.dropFirst(Self.maxEntries) { try? fm.removeItem(at: e.url) }
    }

    public func latest(rootPath: String, before date: Date) -> ScanSummary? {
        all().first { $0.rootPath == rootPath && $0.scannedAt < date }
    }

    public func all() -> [ScanSummary] {
        loadEntries().map(\.summary).sorted { $0.scannedAt > $1.scannedAt }
    }

    private struct VersionProbe: Decodable { var schemaVersion: Int? }

    private func loadEntries() -> [(url: URL, summary: ScanSummary)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var result: [(url: URL, summary: ScanSummary)] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let probe = try? decoder.decode(VersionProbe.self, from: data) else {
                quarantine(url); continue
            }
            if let v = probe.schemaVersion, v > ScanSummary.currentSchemaVersion {
                futureNames.withLock { _ = $0.insert(url.lastPathComponent) }
                continue
            }
            guard let s = try? decoder.decode(ScanSummary.self, from: data) else { quarantine(url); continue }
            result.append((url, s))
        }
        return result
    }

    /// 손상 파일을 corrupt/ 로 옮긴다. 이동 실패 시에도 목록에서는 제외하고 건수에 반영한다.
    private func quarantine(_ url: URL) {
        let fm = FileManager.default
        corruptNames.withLock { _ = $0.insert(url.lastPathComponent) }
        let dir = directory.appendingPathComponent(Self.corruptDirectoryName)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            }
            try fm.moveItem(at: url, to: dest)
        } catch {
            // 이동 실패: 파일은 그대로 두되 로드 대상에서는 제외된다.
        }
    }
}

public enum HistoryDiff {
    /// 폴더 경로 기준 증감(양쪽 topFolders 합집합, 없는 쪽 0), |delta| 내림차순 상위 limit
    public static func topChanges(previous: ScanSummary, current: ScanSummary, limit: Int = 10) -> [SummaryChange] {
        let p = Dictionary(previous.topFolders.map { ($0.path, $0.allocatedSize) }, uniquingKeysWith: { a, _ in a })
        let c = Dictionary(current.topFolders.map { ($0.path, $0.allocatedSize) }, uniquingKeysWith: { a, _ in a })
        return sorted(p, c).prefix(max(0, limit)).map { $0 }
    }

    /// 카테고리별 증감
    public static func categoryChanges(previous: ScanSummary, current: ScanSummary) -> [SummaryChange] {
        sorted(previous.categoryTotals, current.categoryTotals)
    }

    private static func sorted(_ p: [String: Int64], _ c: [String: Int64]) -> [SummaryChange] {
        Set(p.keys).union(c.keys).map { SummaryChange(path: $0, previous: p[$0] ?? 0, current: c[$0] ?? 0) }
            .sorted { abs($0.delta) != abs($1.delta) ? abs($0.delta) > abs($1.delta) : $0.path < $1.path }
    }
}
