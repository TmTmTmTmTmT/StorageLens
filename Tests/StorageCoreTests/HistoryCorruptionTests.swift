import Testing
import Foundation
@testable import StorageCore

struct HistoryCorruptionTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("hc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func summary(_ t: TimeInterval) -> ScanSummary {
        ScanSummary(scannedAt: Date(timeIntervalSince1970: t), rootPath: "/r", categoryTotals: [:], topFolders: [])
    }

    @Test func corruptFileQuarantined() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = HistoryStore(directory: d)
        try s.save(summary(100))
        try "{ not json".write(to: d.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        try Data().write(to: d.appendingPathComponent("empty.json"))
        let all = s.all()
        #expect(all.count == 1)
        #expect(s.corruptFileCount == 2)
        #expect(s.quarantinedFileCount == 2)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: d.appendingPathComponent("bad.json").path))
        #expect(fm.fileExists(atPath: d.appendingPathComponent("corrupt/bad.json").path))
        // 재로드해도 다시 세지 않음
        #expect(s.all().count == 1 && s.corruptFileCount == 2)
    }

    @Test func singleCorruptCountAndRetentionExcludesCorrupt() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = HistoryStore(directory: d)
        try "garbage".write(to: d.appendingPathComponent("x.json"), atomically: true, encoding: .utf8)
        for i in 0..<31 { try s.save(summary(1000 + Double(i))) }
        #expect(s.corruptFileCount == 1)
        #expect(s.all().count == HistoryStore.maxEntries)
        let files = try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasSuffix(".json") }
        #expect(files.count == HistoryStore.maxEntries)
    }

    @Test func futureSchemaSkippedNotDeleted() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = HistoryStore(directory: d)
        try s.save(summary(100))
        let future = d.appendingPathComponent("future.json")
        try #"{"schemaVersion":99,"somethingNew":true}"#.write(to: future, atomically: true, encoding: .utf8)
        #expect(s.all().count == 1)
        #expect(FileManager.default.fileExists(atPath: future.path))
        #expect(s.corruptFileCount == 0 && s.skippedFutureVersionCount == 1)
    }

    @Test func legacyFileWithoutSchemaVersionLoads() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let json = #"{"scannedAt":100,"rootPath":"/r","categoryTotals":{},"topFolders":[]}"#
        try json.write(to: d.appendingPathComponent("old.json"), atomically: true, encoding: .utf8)
        let s = HistoryStore(directory: d)
        #expect(s.all().count == 1 && s.corruptFileCount == 0)
        #expect(summary(1).schemaVersion == 1)
    }

    // MARK: 리소스 로드 상태

    private func resDir(catalog: String?, rules: String? = nil) throws -> URL {
        let d = try tmp()
        if let catalog { try catalog.write(to: d.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8) }
        if let rules { try rules.write(to: d.appendingPathComponent("attribution-rules.json"), atomically: true, encoding: .utf8) }
        return d
    }
    private static let goodEntry = #"{"id":"a","title":"A","pathPatterns":["~/a"],"safety":"safe","method":"trash"}"#
    private static let badEntry = #"{"id":"b","title":"B","safety":"nonsense","method":"trash"}"#

    @Test func catalogOneBadEntryIsPartial() throws {
        let d = try resDir(catalog: "[\(Self.goodEntry),\(Self.badEntry)]", rules: "{}")
        defer { try? FileManager.default.removeItem(at: d) }
        let r = StorageSession.loadResourcesDetailed(bundle: Bundle(for: Token.self), resourcesDirectory: d, environment: [:])
        #expect(r.catalog.entries.map(\.id) == ["a"])
        #expect(r.catalogStatus == .partial(skipped: 1))
        #expect(r.rulesStatus == .ok)
    }

    @Test func missingFilesReported() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let empty = try tmp(); defer { try? FileManager.default.removeItem(at: empty) }
        let r = StorageSession.loadResourcesDetailed(bundle: Bundle(for: Token.self), resourcesDirectory: d,
                                                     environment: [:], packageRoot: empty)
        if case .missing = r.catalogStatus {} else { Issue.record("catalog status \(r.catalogStatus)") }
        if case .missing = r.rulesStatus {} else { Issue.record("rules status \(r.rulesStatus)") }
        #expect(r.catalog.entries.isEmpty)
    }

    @Test func invalidJSONReported() throws {
        let d = try resDir(catalog: "not json", rules: "[1,2]")
        defer { try? FileManager.default.removeItem(at: d) }
        let r = StorageSession.loadResourcesDetailed(bundle: Bundle(for: Token.self), resourcesDirectory: d, environment: [:])
        if case .invalid = r.catalogStatus {} else { Issue.record("catalog status \(r.catalogStatus)") }
        if case .invalid = r.rulesStatus {} else { Issue.record("rules status \(r.rulesStatus)") }
    }

    @Test func envVarFallbackAndSessionStatus() throws {
        let d = try resDir(catalog: "[\(Self.goodEntry)]", rules: #"{"pathRules":[{"path":"~/x","appName":"X"},{"bad":1}]}"#)
        defer { try? FileManager.default.removeItem(at: d) }
        let s = StorageSession(home: d, bundle: Bundle(for: Token.self), historyDirectory: d.appendingPathComponent("h"),
                               environment: [StorageSession.resourcesDirEnvVar: d.path])
        #expect(s.catalogLoadStatus == .ok && s.hasCatalog)
        #expect(s.rulesLoadStatus == .partial(skipped: 1) && s.hasRules)
    }

    @Test func realResourcesLoadCleanly() {
        let r = StorageSession.loadResourcesDetailed(bundle: Bundle(for: Token.self), environment: [:])
        #expect(r.catalogStatus == .ok && !r.catalog.entries.isEmpty)
        #expect(r.rulesStatus == .ok && !r.rules.pathRules.isEmpty)
    }
}

private final class Token {}
