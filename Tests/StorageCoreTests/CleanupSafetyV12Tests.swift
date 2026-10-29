import Testing
import Foundation
@testable import StorageCore

// v1.2 A1 (Cleanup 코어 안전) 신규 테스트. 홈은 항상 임시 디렉터리. 휴지통 테스트는 `StorageLensTest-` 접두 항목만 사용·정리한다.

private final class V12Env {
    let root: URL
    let home: URL
    let journalURL: URL
    var trashed: [String] = []
    var restoreModes: [(String, mode_t)] = []
    let fm = FileManager.default

    init() throws {
        let base = try SystemFileSystem().realPath(of: URL(fileURLWithPath: NSTemporaryDirectory()))
        root = base.appendingPathComponent("StorageLensTest-v12-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        journalURL = root.appendingPathComponent("journal/journal.jsonl")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try mkdir("Library/Caches")
        try mkdir("Library/Mobile Documents")
    }

    func teardown() {
        for (p, m) in restoreModes { chmod(p, m) }
        for t in trashed where t.contains(".Trash") && URL(fileURLWithPath: t).lastPathComponent.hasPrefix("StorageLensTest-") {
            try? fm.removeItem(atPath: t)
        }
        try? fm.removeItem(at: root)
    }

    func p(_ rel: String) -> String { home.appendingPathComponent(rel).path }
    @discardableResult func mkdir(_ rel: String) throws -> String {
        try fm.createDirectory(atPath: p(rel), withIntermediateDirectories: true); return p(rel)
    }
    @discardableResult func file(_ rel: String, _ content: String = "hello") throws -> String {
        try fm.createDirectory(atPath: (p(rel) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: p(rel), atomically: true, encoding: .utf8)
        return p(rel)
    }
    func lock(_ rel: String) {
        restoreModes.append((p(rel), 0o755))
        chmod(p(rel), 0o000)
    }

    static func catalog() -> Catalog {
        return try! TestSupport.loadCatalog()
    }

    func cleaner(catalog: Catalog = V12Env.catalog(), fs: any FileSystem = SystemFileSystem(),
                 uploadChecker: @escaping ICloudUploadChecker = { _ in .uploaded }) -> Cleaner {
        let m = CatalogMatcher(catalog: catalog, home: home.path, toolResolver: { _ in nil })
        return Cleaner(home: home, matcher: m, fileSystem: fs,
                       toolLocator: ToolLocator(home: home, candidateDirectories: []),
                       journal: Journal(fileURL: journalURL), uploadChecker: uploadChecker)
    }
}

private final class EvictCountingFS: FileSystem, @unchecked Sendable {
    private let base = SystemFileSystem()
    private let lock = NSLock()
    private(set) var evicted: [String] = []
    func entries(in directory: URL) throws -> [FileEntry] { try base.entries(in: directory) }
    func attributes(at url: URL) throws -> FileEntry { try base.attributes(at: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func realPath(of url: URL) throws -> URL { try base.realPath(of: url) }
    func trashItem(at url: URL) throws -> URL? { try base.trashItem(at: url) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func evictUbiquitousItem(at url: URL) throws { lock.lock(); evicted.append(url.path); lock.unlock() }
}

@Suite struct CleanupSafetyV12Tests {

    // MARK: - safety-3 읽기 불가 하위 폴더 fail-closed

    @Test func unreadableSubfolderWithPhotosLibraryIsRejected() throws {
        let env = try V12Env(); defer { env.teardown() }
        try env.mkdir("Library/Caches/StorageLensTest-big/locked/My.photoslibrary")
        env.lock("Library/Caches/StorageLensTest-big/locked")
        let plan = env.cleaner().plan([CleanupSelection(path: env.p("Library/Caches/StorageLensTest-big"))])
        #expect(plan.items.isEmpty)
        #expect(plan.rejected.first?.reason.contains("하위 폴더를 읽을 수 없어 안전 확인 불가") == true)
    }

    @Test func unreadableSubfolderAloneIsRejected() throws {
        let env = try V12Env(); defer { env.teardown() }
        try env.file("Library/Caches/StorageLensTest-ro/ok/a.txt")
        try env.mkdir("Library/Caches/StorageLensTest-ro/locked")
        env.lock("Library/Caches/StorageLensTest-ro/locked")
        let plan = env.cleaner().plan([CleanupSelection(path: env.p("Library/Caches/StorageLensTest-ro"))])
        #expect(plan.items.isEmpty && plan.rejected.count == 1)
        #expect(plan.rejected[0].reason.contains("읽을 수 없어"))
    }

    // MARK: - safety-8 / perf-5 통합 순회, 진행 콜백, 크기

    @Test func planMeasuresSizeInSingleWalkAndReportsProgress() throws {
        let env = try V12Env(); defer { env.teardown() }
        for i in 0..<600 { try env.file("Library/Caches/StorageLensTest-n/d\(i % 5)/f\(i).txt", String(repeating: "x", count: 100)) }
        final class Box: @unchecked Sendable { var calls = 0; var maxProcessed = 0; let l = NSLock() }
        let box = Box()
        let plan = env.cleaner().plan([CleanupSelection(path: env.p("Library/Caches/StorageLensTest-n"))]) { pr in
            box.l.lock(); box.calls += 1; box.maxProcessed = max(box.maxProcessed, pr.processedCount); box.l.unlock()
        }
        let item = try #require(plan.items.first)
        #expect(item.sizeBytes >= 600 * 100 && item.unmeasuredCount == 0 && plan.unmeasuredCount == 0)
        #expect(box.calls > 0 && box.maxProcessed >= 600)
    }

    // MARK: - safety-4 undo 동일성

    private func trashOne(_ env: V12Env, _ c: Cleaner, name: String) async throws -> (JournalEntry, String) {
        let dir = try env.mkdir("Library/Caches/\(name)")
        try env.file("Library/Caches/\(name)/f.bin", String(repeating: "q", count: 5000))
        let r = await c.execute(c.plan([CleanupSelection(path: dir)]))
        let out = try #require(r.outcomes.first)
        if let t = out.trashedPath { env.trashed.append(t) }
        #expect(out.status == .succeeded, "\(out.reason ?? "")")
        let e = try #require(c.journal.entries().last { $0.originalPath == dir })
        #expect(e.trashDev != nil && e.trashInode != nil && e.trashSize != nil)
        return (e, dir)
    }

    @Test func undoRejectedWhenTrashItemIsDifferentFileWithSameName() async throws {
        let env = try V12Env(); defer { env.teardown() }
        let c = env.cleaner()
        let (e, dir) = try await trashOne(env, c, name: "StorageLensTest-same-\(UUID().uuidString)")
        #expect(c.canUndo(e).0)
        // 휴지통 항목을 같은 이름의 다른 항목(다른 inode)으로 교체
        let tp = try #require(e.trashPath)
        try FileManager.default.removeItem(atPath: tp)
        try FileManager.default.createDirectory(atPath: tp, withIntermediateDirectories: true)
        try "different content, different size".write(toFile: tp + "/other.txt", atomically: true, encoding: .utf8)
        let (ok, why) = c.canUndo(e)
        #expect(!ok && why?.contains("기록과 다릅니다") == true)
        let u = c.undo(e)
        #expect(!u.success)
        #expect(!FileManager.default.fileExists(atPath: dir))
    }

    @Test func undoRejectedForOldJournalEntryWithoutIdentity() async throws {
        let env = try V12Env(); defer { env.teardown() }
        let c = env.cleaner()
        var (e, dir) = try await trashOne(env, c, name: "StorageLensTest-old-\(UUID().uuidString)")
        e.trashDev = nil; e.trashInode = nil; e.trashSize = nil
        let (ok, why) = c.canUndo(e)
        #expect(!ok && why?.contains("구버전") == true)
        #expect(!c.undo(e).success)
        #expect(!FileManager.default.fileExists(atPath: dir))
        // 구기록 JSON(필드 없음) 디코딩 호환
        let json = #"{"timestamp":"2026-01-01T00:00:00Z","originalPath":"/a","trashPath":"/b/.Trash/x","sizeBytes":1,"method":"trash","result":"success"}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let old = try dec.decode(JournalEntry.self, from: Data(json.utf8))
        #expect(old.trashInode == nil && old.trashDev == nil && old.trashSize == nil)
    }

    @Test func undoRejectedForTrashPathOutsideTrash() async throws {
        let env = try V12Env(); defer { env.teardown() }
        let c = env.cleaner()
        var (e, _) = try await trashOne(env, c, name: "StorageLensTest-out-\(UUID().uuidString)")
        // "/.Trash/" 문자열만 포함하는 임의 경로 (실제 휴지통이 아님)
        let fake = env.p("Library/Caches/x/.Trash/victim.txt")
        try env.file("Library/Caches/x/.Trash/victim.txt")
        e.trashPath = fake
        let (ok, why) = c.canUndo(e)
        #expect(!ok && why?.contains("휴지통 경로가 아닙니다") == true)
        // 휴지통 접두지만 ".." 로 탈출
        e.trashPath = NSHomeDirectory() + "/.Trash/../Documents/x"
        #expect(!c.canUndo(e).0)
    }

    // MARK: - safety-5 / cq-9 저널

    @Test func appendAfterTruncatedLineKeepsSecondEntryAndReportsCorruption() throws {
        let env = try V12Env(); defer { env.teardown() }
        let j = Journal(fileURL: env.journalURL)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try j.append(JournalEntry(timestamp: t, originalPath: "/a", trashPath: nil, sizeBytes: 1, method: "command", result: "success"))
        // 개행 없이 잘린 줄
        let h = try FileHandle(forWritingTo: env.journalURL)
        try h.seekToEnd(); try h.write(contentsOf: Data(#"{"timestamp":"2026-01-01T00:0"#.utf8)); try h.close()
        try j.append(JournalEntry(timestamp: t, originalPath: "/b", trashPath: nil, sizeBytes: 2, method: "command", result: "success"))
        let r = j.read()
        #expect(r.entries.map(\.originalPath) == ["/a", "/b"])
        #expect(r.corruptLineCount == 1)
        #expect(j.entries().count == 2)
    }

    @Test func concurrentAppendFromTwoInstances() throws {
        let env = try V12Env(); defer { env.teardown() }
        let j1 = Journal(fileURL: env.journalURL), j2 = Journal(fileURL: env.journalURL)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        DispatchQueue.concurrentPerform(iterations: 2) { k in
            let j = k == 0 ? j1 : j2
            for i in 0..<50 {
                try? j.append(JournalEntry(timestamp: t, originalPath: "/w\(k)-\(i)", trashPath: nil, sizeBytes: Int64(i),
                                           method: "command", result: "success", detail: String(repeating: "d", count: 200)))
            }
        }
        let r = j1.read()
        #expect(r.entries.count == 100 && r.corruptLineCount == 0)
        #expect(Set(r.entries.map(\.originalPath)).count == 100)
        #expect(Journal.shared(fileURL: env.journalURL) === Journal.shared(fileURL: env.journalURL))
    }

    // MARK: - safety-6 iCloud 업로드 확인

    @Test func notUploadedICloudFilesAreSkippedWithCapAndSummary() async throws {
        let env = try V12Env(); defer { env.teardown() }
        let base = "Library/Mobile Documents/com~apple~CloudDocs"
        try env.file("\(base)/done.txt")
        for i in 0..<130 { try env.file("\(base)/pending/p\(i).txt") }
        let fs = EvictCountingFS()
        let c = env.cleaner(fs: fs, uploadChecker: { url in
            url.path.contains("/pending/") ? .notUploaded("업로드 대기") : .uploaded
        })
        let m = CatalogMatcher(catalog: V12Env.catalog(), home: env.home.path, toolResolver: { _ in nil })
        _ = m
        let plan = c.plan([CleanupSelection(path: env.p("Library/Mobile Documents"))])
        let out = try #require(await c.execute(plan).outcomes.first)
        #expect(fs.evicted.map { ($0 as NSString).lastPathComponent } == ["done.txt"])
        #expect(out.status == .partial)
        #expect(out.notUploadedCount == 130)
        #expect(out.skippedFiles.count == Cleaner.maxListedFailures && out.omittedSkippedCount == 30)
        #expect(out.skippedFiles[0].reason.contains("업로드"))
        #expect(out.failures.isEmpty)
    }

    @Test func allNotUploadedEvictsNothing() async throws {
        let env = try V12Env(); defer { env.teardown() }
        try env.file("Library/Mobile Documents/com~apple~CloudDocs/a.txt")
        let fs = EvictCountingFS()
        let c = env.cleaner(fs: fs, uploadChecker: { _ in .notUploaded("업로드 중") })
        let out = try #require(await c.execute(c.plan([CleanupSelection(path: env.p("Library/Mobile Documents"))])).outcomes.first)
        #expect(fs.evicted.isEmpty && out.status == .skipped && out.notUploadedCount == 1)
    }

    // MARK: - safety-2 빈 카탈로그

    @Test func emptyCatalogRejectsEverythingAndSkipsExecute() async throws {
        let env = try V12Env(); defer { env.teardown() }
        let dir = try env.mkdir("Library/Caches/StorageLensTest-e")
        let c = env.cleaner(catalog: Catalog(entries: []))
        let plan = c.plan([CleanupSelection(path: dir)])
        #expect(plan.items.isEmpty && plan.rejected.count == 1)
        #expect(plan.rejected[0].reason.contains("카탈로그를 불러오지 못해"))
        // 정상 카탈로그로 만든 계획을 빈 카탈로그 Cleaner로 실행해도 전부 skipped
        let good = env.cleaner().plan([CleanupSelection(path: dir)])
        let r = await c.execute(good)
        #expect(r.outcomes.allSatisfy { $0.status == .skipped } && FileManager.default.fileExists(atPath: dir))
    }

    // MARK: - safety-7 취소

    @Test func executeInCancelledTaskSkipsRemainingItemsAndJournalsThem() async throws {
        let env = try V12Env(); defer { env.teardown() }
        let a = try env.mkdir("Library/Caches/StorageLensTest-c1")
        let b = try env.mkdir("Library/Caches/StorageLensTest-c2")
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: a), CleanupSelection(path: b)])
        #expect(plan.items.count == 2)
        let t = Task { () -> CleanupResult in
            while !Task.isCancelled { await Task.yield() }
            return await c.execute(plan)
        }
        t.cancel()
        let r = await t.value
        #expect(r.outcomes.count == 2)
        #expect(r.outcomes.allSatisfy { $0.status == .skipped && $0.reason == "취소됨" })
        #expect(FileManager.default.fileExists(atPath: a) && FileManager.default.fileExists(atPath: b))
        let js = c.journal.entries()
        #expect(js.count == 2 && js.allSatisfy { $0.result == "skipped" && $0.detail == "취소됨" })
    }

    @Test func planInCancelledTaskRejectsAsCancelled() async throws {
        let env = try V12Env(); defer { env.teardown() }
        let a = try env.mkdir("Library/Caches/StorageLensTest-pc")
        let c = env.cleaner()
        let t = Task { () -> CleanupPlan in
            while !Task.isCancelled { await Task.yield() }
            return c.plan([CleanupSelection(path: a)])
        }
        t.cancel()
        let plan = await t.value
        #expect(plan.items.isEmpty && plan.rejected.first?.reason == "취소됨")
    }
}
