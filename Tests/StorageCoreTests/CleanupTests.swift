import Testing
import Foundation
@testable import StorageCore

// 주의: 이 파일은 실제 사용자 데이터를 건드리지 않는다. 홈은 항상 임시 디렉터리로 주입한다.
// 실제 trashItem 테스트는 임시 홈 안의 `StorageLensTest-` 접두 파일만 사용하고,
// 끝에서 resultingItemURL로 옮겨진 그 파일만 정리한다.
//
// "plan 없이 execute 불가"는 컴파일 수준에서 보장된다: CleanupPlan/CleanupPlanItem의 init이 internal 이라
// 외부 모듈은 Cleaner.plan() 외에는 CleanupPlan을 만들 수 없고, execute는 CleanupPlan만 받는다.
// (이 테스트는 @testable import 이므로 internal init을 쓸 수 있으나, 제품 코드 경로에서는 불가능.)

private final class MutableClock: StorageCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

private struct FakeInUse: InUseQuery {
    let names: [String]
    func processes(usingPathPrefix path: String) -> [String] { names }
}

/// SystemFileSystem 위임 + evict 호출 기록 (실제 iCloud 없이 evict 경로 검증).
private final class RecordingFS: FileSystem, @unchecked Sendable {
    private let base = SystemFileSystem()
    private let lock = NSLock()
    private(set) var evicted: [String] = []
    let failNames: Set<String>
    init(failNames: Set<String> = []) { self.failNames = failNames }
    func entries(in directory: URL) throws -> [FileEntry] { try base.entries(in: directory) }
    func attributes(at url: URL) throws -> FileEntry { try base.attributes(at: url) }
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func realPath(of url: URL) throws -> URL { try base.realPath(of: url) }
    func trashItem(at url: URL) throws -> URL? { try base.trashItem(at: url) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func evictUbiquitousItem(at url: URL) throws {
        if failNames.contains(url.lastPathComponent) {
            throw NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "not uploaded"])
        }
        lock.lock(); evicted.append(url.path); lock.unlock()
    }
}

private final class Env {
    let root: URL
    let home: URL
    let bin: URL
    let journalURL: URL
    var trashed: [String] = []
    let fm = FileManager.default

    init() throws {
        let base = try SystemFileSystem().realPath(of: URL(fileURLWithPath: NSTemporaryDirectory()))
        root = base.appendingPathComponent("StorageLensTest-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        bin = root.appendingPathComponent("bin")
        journalURL = root.appendingPathComponent("journal/journal.jsonl")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for rel in PathSafety.deniedRoots.map(\.rel) { try mkdir(rel) }
        try mkdir("Library/Caches")
        try mkdir(".cache/uv")
        try mkdir("Downloads")
    }

    func teardown() {
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
    func script(_ name: String, _ body: String) throws {
        let path = bin.appendingPathComponent(name).path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o755)
    }

    func cleaner(fs: any FileSystem = SystemFileSystem(), clock: any StorageCore.Clock = SystemClock(),
                 inUse: (any InUseQuery)? = nil, timeout: TimeInterval = 600,
                 attribution: @escaping @Sendable (String) -> Attribution? = { _ in nil },
                 uploadChecker: @escaping ICloudUploadChecker = { _ in .uploaded }) -> Cleaner {
        Cleaner(home: home, matcher: matcher(clock: clock), attributionLookup: attribution, fileSystem: fs, clock: clock,
                toolLocator: ToolLocator(home: home, candidateDirectories: [bin.path], systemToolDirectory: bin.path),
                inUse: inUse, journal: Journal(fileURL: journalURL), commandTimeout: timeout,
                uploadChecker: uploadChecker)
    }

    func matcher(clock: any StorageCore.Clock = SystemClock()) -> CatalogMatcher {
        let loc = ToolLocator(home: home, candidateDirectories: [bin.path], systemToolDirectory: bin.path)
        return CatalogMatcher(catalog: realCatalog(), home: home.path, clock: clock,
                              toolResolver: { loc.locate($0).map { URL(fileURLWithPath: $0) } })
    }
}

private func realHome(_ u: URL) -> URL {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(u.path, &buf) != nil else { return u }
    return URL(fileURLWithPath: String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
}

private func realCatalog() -> Catalog {
    return try! TestSupport.loadCatalog()
}

private func entry(_ id: String, safety: Safety = .safe, method: CleanupMethod = .trash,
                   command: CatalogCommand? = nil, patterns: [String] = ["x"]) -> CatalogEntry {
    CatalogEntry(id: id, title: id, pathPatterns: patterns, safety: safety, method: method, command: command, note: "note")
}
private func match(_ e: CatalogEntry, root: String = "", effective: CleanupMethod? = nil, reason: String? = nil) -> CatalogMatch {
    CatalogMatch(entry: e, matchedRoot: root, effectiveMethod: effective ?? e.method, unavailableReason: reason, toolURL: nil)
}

@Suite struct CleanupTests {

    private func rejectedReason(_ plan: CleanupPlan, _ path: String) -> String? {
        plan.rejected.first { $0.path == path }?.reason
    }

    // MARK: - 거부 목록 / 홈 / 링크

    private static let hardRels = ["Library/Keychains", "Library/Mail", "Library/Messages", "Library/Photos", ".ssh", ".gnupg"]
    private static let selfOnlyRels = ["Library", "Documents", "Desktop", "Pictures", "Movies", "Music", "Downloads",
                                       "Library/Application Support", "Library/Containers", "Library/Group Containers",
                                       "Library/Caches", "Library/Preferences", ".cache"]

    @Test func deniedRootsMatchSpec() {
        // 하드 차단 7(Mobile Documents 포함) + 자체만 차단 13. 홈 자체는 별도 처리.
        #expect(PathSafety.deniedRoots.filter(\.withDescendants).count == 7)
        #expect(PathSafety.deniedRoots.filter { !$0.withDescendants }.map(\.rel).sorted() == Self.selfOnlyRels.sorted())
        #expect(!PathSafety.deniedRoots.contains { $0.rel == ".cache/huggingface" })
    }

    @Test func hardDeniedPathsRejectedSelfDescendantsAndAncestors() throws {
        let env = try Env(); defer { env.teardown() }
        let c = env.cleaner()
        var plan = c.plan([CleanupSelection(path: env.home.path)])
        #expect(plan.items.isEmpty && plan.rejected.count == 1)
        for rel in Self.hardRels {
            plan = c.plan([CleanupSelection(path: env.p(rel))])
            #expect(plan.items.isEmpty, "자체 거부: \(rel)")
            let child = try env.file(rel + "/child.txt")
            let sub = try env.mkdir(rel + "/subdir")
            plan = c.plan([CleanupSelection(path: child), CleanupSelection(path: sub)])
            #expect(plan.items.isEmpty && plan.rejected.count == 2, "하위 거부: \(rel)")
        }
        // 상위 폴더 (Library 는 자체만 차단 목록이기도 함)
        #expect(c.plan([CleanupSelection(path: env.p("Library"))]).items.isEmpty)
        // 상위 폴더 규칙: Keychains 를 품은 임의 상위 폴더
        try env.mkdir("Stuff/Library/Keychains")
        #expect(c.plan([CleanupSelection(path: env.p("Stuff/Library"))]).items.count == 1)   // 홈의 보호 경로가 아니므로 허용
        #expect(c.plan([CleanupSelection(path: env.p(".cache/huggingface/../"))]).items.isEmpty)
    }

    @Test func selfOnlyDeniedRejectedButChildrenAllowed() throws {
        let env = try Env(); defer { env.teardown() }
        let c = env.cleaner()
        for rel in Self.selfOnlyRels {
            let plan = c.plan([CleanupSelection(path: env.p(rel))])
            #expect(plan.items.isEmpty && plan.rejected.count == 1, "자체 거부: \(rel)")
        }
        let children = [
            try env.file("Documents/a.txt"), try env.file("Desktop/a.txt"), try env.file("Pictures/a.jpg"),
            try env.file("Movies/a.mov"), try env.file("Music/a.mp3"), try env.file("Downloads/a.zip"),
            try env.mkdir("Library/Application Support/Foo"), try env.mkdir("Library/Containers/com.x.y"),
            try env.mkdir("Library/Group Containers/group.x"), try env.mkdir("Library/Caches/StorageLensTest-c"),
            try env.file("Library/Preferences/com.x.y.plist"), try env.mkdir(".cache/foo"),
        ]
        let plan = c.plan(children.map { CleanupSelection(path: $0) })
        #expect(plan.items.count == children.count, "\(plan.rejected)")
    }

    @Test func photosLibraryRejectedEverywhere() throws {
        let env = try Env(); defer { env.teardown() }
        let c = env.cleaner()
        let lib = try env.mkdir("Pictures/Trip.photoslibrary")
        let inner = try env.file("Pictures/Trip.photoslibrary/database/x.db")
        let upper = try env.mkdir("Pictures/UPPER.PhotosLibrary")
        let elsewhere = try env.mkdir("Library/Caches/StorageLensTest-p/Old.photoslibrary/originals")
        let holder = env.p("Library/Caches/StorageLensTest-p")
        let deepHolder = try env.mkdir("Documents/proj/a/b/Backup.photoslibrary")
        var plan = c.plan([CleanupSelection(path: lib), CleanupSelection(path: inner), CleanupSelection(path: upper),
                           CleanupSelection(path: (elsewhere as NSString).deletingLastPathComponent),
                           CleanupSelection(path: elsewhere),
                           CleanupSelection(path: holder),                                  // 하위에 photoslibrary
                           CleanupSelection(path: env.p("Documents/proj")),                 // 깊은 하위
                           CleanupSelection(path: deepHolder)])
        #expect(plan.items.isEmpty && plan.rejected.count == 8, "\(plan.items.map(\.path))")
        // 링크 너머의 photoslibrary 는 따라가지 않음: 링크 자체는 다른 이유로 거부되지 않는 폴더 안에 둔다.
        let safeDir = try env.mkdir("Library/Caches/StorageLensTest-q")
        let target = try env.mkdir("Pictures/Z.photoslibrary/x")
        try FileManager.default.createSymbolicLink(atPath: safeDir + "/lnk", withDestinationPath: (target as NSString).deletingLastPathComponent)
        plan = c.plan([CleanupSelection(path: safeDir)])
        #expect(plan.items.count == 1)
    }

    @Test func huggingFaceAllowedAsDiscouraged() throws {
        let env = try Env(); defer { env.teardown() }
        let hf = try env.mkdir(".cache/huggingface")
        let sub = try env.mkdir(".cache/huggingface/hub/models--a--b")
        let plan = env.cleaner().plan([CleanupSelection(path: hf), CleanupSelection(path: sub)])
        #expect(plan.items.count == 2 && plan.items.allSatisfy { $0.isDiscouraged && $0.method == .trash })
        #expect(plan.items[0].warnings.contains { $0.contains("정리 비권장") })
    }

    @Test func discouragedRequiresAcknowledgement() async throws {
        let env = try Env(); defer { env.teardown() }
        let f = try env.file("Library/Application Support/StorageLensTest-d/a.txt")
        let dir = (f as NSString).deletingLastPathComponent
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: dir)])
        let item = try #require(plan.items.first)
        #expect(item.isDiscouraged && item.entryID == "app-support")
        var r = await c.execute(plan)
        #expect(r.outcomes[0].status == .skipped && r.outcomes[0].reason == "비권장 항목 확인 안 됨")
        #expect(FileManager.default.fileExists(atPath: f))
        // 계획의 isDiscouraged 를 false 로 위조해도 실행 직전 재계산으로 막힌다.
        let forged = CleanupPlanItem(path: item.path, sizeBytes: item.sizeBytes, method: item.method,
                                     inode: item.inode, devID: item.devID, isDiscouraged: false)
        r = await c.execute(CleanupPlan(createdAt: Date(), items: [forged]))
        #expect(r.outcomes[0].status == .skipped && r.outcomes[0].reason == "비권장 항목 확인 안 됨")
        #expect(FileManager.default.fileExists(atPath: f))
        // 확인 시 휴지통으로 이동
        r = await c.execute(plan, acknowledgedDiscouraged: true)
        if let t = r.outcomes[0].trashedPath { env.trashed.append(t) }
        #expect(r.outcomes[0].status == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: f))
    }

    @Test func unclassifiedPersonalFolderPathIsDiscouraged() throws {
        let env = try Env(); defer { env.teardown() }
        // 개인 폴더 패턴이 없는 카탈로그 -> 폴백 규칙
        let loc = ToolLocator(home: env.home, candidateDirectories: [])
        // 빈 카탈로그는 전부 거부되므로 더미 항목 1개(어떤 경로에도 매칭되지 않음)를 둔다.
        let m = CatalogMatcher(catalog: Catalog(entries: [entry("dummy", patterns: ["~/NoSuchDummyPath"])]), home: env.home.path, toolResolver: { loc.locate($0).map { URL(fileURLWithPath: $0) } })
        let c = Cleaner(home: env.home, matcher: m, journal: Journal(fileURL: env.journalURL))
        let doc = try env.file("Documents/proj/a.txt")
        let other = try env.file("Projects/b.txt")
        let plan = c.plan([CleanupSelection(path: doc), CleanupSelection(path: other)])
        #expect(plan.items.count == 2)
        #expect(plan.items[0].isDiscouraged && !plan.items[1].isDiscouraged)
        #expect(plan.items[1].warnings.contains { $0.contains("카탈로그에 없는") })
        #expect(m.isUnderPersonalFolder(env.p("Music/x")) && !m.isUnderPersonalFolder(env.p("Music")))
    }

    @Test func caseVariantOfDeniedPathRejected() throws {
        let env = try Env(); defer { env.teardown() }
        let plan = env.cleaner().plan([CleanupSelection(path: env.p("documents")),
                                       CleanupSelection(path: env.p("DOCUMENTS/x"))])
        #expect(plan.items.isEmpty)
    }

    @Test func outsideHomeRejected() throws {
        let env = try Env(); defer { env.teardown() }
        let outside = env.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let plan = env.cleaner().plan([CleanupSelection(path: outside.path),
                                       CleanupSelection(path: "/usr/bin"),
                                       CleanupSelection(path: "relative/path"),
                                       CleanupSelection(path: env.p("Downloads/../../outside"))])
        #expect(plan.items.isEmpty && plan.rejected.count == 4)
    }

    @Test func symlinkRejected() throws {
        let env = try Env(); defer { env.teardown() }
        let outside = env.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        // 홈 안의 링크 -> 홈 밖
        try FileManager.default.createSymbolicLink(atPath: env.p("Downloads/link"), withDestinationPath: outside.path)
        // 중간 링크 경유
        let viaMiddle = env.p("Downloads/link/f.txt")
        // 링크 -> 홈 안의 보호 경로
        try FileManager.default.createSymbolicLink(atPath: env.p("Library/Caches/sshlink"), withDestinationPath: env.p(".ssh"))
        let plan = env.cleaner().plan([CleanupSelection(path: env.p("Downloads/link")),
                                       CleanupSelection(path: viaMiddle),
                                       CleanupSelection(path: env.p("Library/Caches/sshlink")),
                                       CleanupSelection(path: env.p("Library/Caches/sshlink/id_rsa"))])
        #expect(plan.items.isEmpty && plan.rejected.count == 4)
        #expect(rejectedReason(plan, viaMiddle)?.contains("심볼릭") == true)
    }

    @Test func homeGivenViaSymlinkedPrefixStillWorks() throws {
        // 홈을 심볼릭 링크 경로로 주입해도 realpath 기준으로 동작
        let env = try Env(); defer { env.teardown() }
        let linkHome = env.root.appendingPathComponent("homelink")
        try FileManager.default.createSymbolicLink(at: linkHome, withDestinationURL: env.home)
        let loc = ToolLocator(home: linkHome, candidateDirectories: [])
        let m = CatalogMatcher(catalog: realCatalog(), home: realHome(env.home).path, toolResolver: { loc.locate($0).map { URL(fileURLWithPath: $0) } })
        let c = Cleaner(home: linkHome, matcher: m, toolLocator: ToolLocator(home: linkHome, candidateDirectories: []),
                        journal: Journal(fileURL: env.journalURL))
        let dir = try env.file("Library/Caches/StorageLensTest-l/a")
        let viaLink = linkHome.appendingPathComponent("Library/Caches/StorageLensTest-l").path
        #expect(c.plan([CleanupSelection(path: viaLink)]).items.count == 1)
        _ = dir
        #expect(c.plan([CleanupSelection(path: linkHome.appendingPathComponent("Documents").path)]).items.isEmpty)
    }

    @Test func matcherHomeMismatchRejectsAll() async throws {
        // 매처 홈(심볼릭 경로) != Cleaner realpath 홈 -> 전부 rejected, execute는 전부 skipped
        let env = try Env(); defer { env.teardown() }
        let linkHome = env.root.appendingPathComponent("homelink2")
        try FileManager.default.createSymbolicLink(at: linkHome, withDestinationURL: env.home)
        let loc = ToolLocator(home: env.home, candidateDirectories: [])
        let m = CatalogMatcher(catalog: realCatalog(), home: linkHome.path, toolResolver: { loc.locate($0).map { URL(fileURLWithPath: $0) } })
        let c = Cleaner(home: realHome(env.home), matcher: m, journal: Journal(fileURL: env.journalURL))
        let dir = try env.mkdir("Library/Caches/StorageLensTest-m")
        let hf = try env.mkdir(".cache/huggingface/hub")
        let plan = c.plan([CleanupSelection(path: dir), CleanupSelection(path: hf)])
        #expect(plan.items.isEmpty && plan.rejected.count == 2)
        #expect(plan.rejected.allSatisfy { $0.reason.contains("홈 불일치") })
        let fake = CleanupPlanItem(path: dir, sizeBytes: 0, method: .trash, inode: 0, devID: 0, warnings: [])
        let res = await c.execute(CleanupPlan(createdAt: Date(), items: [fake], rejected: []))
        #expect(res.outcomes.allSatisfy { $0.status == .skipped })
    }

    // MARK: - 카탈로그 기반 거부

    @Test func discouragedCatalogAndToolMissing() throws {
        let env = try Env(); defer { env.teardown() }
        let dir = try env.mkdir("Library/Application Support/SomeApp")
        let hf = try env.mkdir(".cache/huggingface/hub")
        let cont = try env.mkdir("Library/Containers/com.x.y")
        let c = env.cleaner()
        // 호출자가 가짜 safe 매치를 붙여도 Cleaner가 직접 계산하므로 무시된다.
        let fakeSafe = match(entry("user-caches"))
        let plan = c.plan([CleanupSelection(path: dir, match: fakeSafe),
                           CleanupSelection(path: env.p(".cache/uv")),            // uv 도구 없음
                           CleanupSelection(path: hf, match: fakeSafe),
                           CleanupSelection(path: cont)])
        #expect(plan.items.count == 3 && plan.rejected.count == 1)
        #expect(plan.items.allSatisfy { $0.isDiscouraged && $0.method == .trash })
        #expect(plan.rejected[0].reason == "도구 없음")
    }

    @Test func savedStateSafePreferencesDiscouraged() throws {
        let env = try Env(); defer { env.teardown() }
        let ss = try env.mkdir("Library/Saved Application State/com.x.savedState")
        let pref = try env.file("Library/Preferences/com.x.plist")
        let apple = try env.file("Library/Preferences/com.apple.finder.plist")
        let plan = env.cleaner().plan([CleanupSelection(path: ss), CleanupSelection(path: pref), CleanupSelection(path: apple)])
        #expect(plan.items.map(\.isDiscouraged) == [false, true, false])
        #expect(plan.items[0].entryID == "saved-state" && plan.items[1].entryID == "app-preferences")
        #expect(plan.items[2].entryID == nil)
    }

    @Test func orphanAttributionAllowsReviewTrash() throws {
        let env = try Env(); defer { env.teardown() }
        let dir = try env.mkdir("Library/Application Support/com.gone.app")
        let orphan = Attribution(appName: "x", confidence: .inferred, rule: "r", isOrphanSuspect: true)
        let c = env.cleaner(attribution: { $0.hasSuffix("com.gone.app") ? orphan : nil })
        let plan = c.plan([CleanupSelection(path: dir)])
        let item = try #require(plan.items.first)
        #expect(item.entryID == "orphan" && item.method == .trash)
        #expect(item.warnings.contains { $0.contains("검토") })
    }

    @Test func virtualItemMustExistInCatalogWithoutPatterns() throws {
        let env = try Env(); defer { env.teardown() }
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(virtual: match(entry("user-caches", patterns: []))),
                           CleanupSelection(virtual: match(entry("orphan", patterns: []))),
                           CleanupSelection(virtual: match(entry("nope", patterns: [])))])
        #expect(plan.items.isEmpty && plan.rejected.count == 3)
    }

    @Test func mobileDocumentsAlwaysEvictNeverTrash() throws {
        let env = try Env(); defer { env.teardown() }
        let md = env.p("Library/Mobile Documents")
        let f = try env.file("Library/Mobile Documents/com~apple~CloudDocs/doc.txt")
        let c = env.cleaner()
        let plan = c.plan([
            CleanupSelection(path: md, match: match(entry("x", method: .trash))),   // 호출자 매치 무시 -> evict
            CleanupSelection(path: f),
            CleanupSelection(path: env.p("Library")),
        ])
        #expect(plan.items.map(\.path) == [md, f])
        #expect(plan.items.allSatisfy { $0.method == .icloudEvict })
        #expect(plan.rejected.count == 1)
    }

    @Test func warnings() throws {
        let env = try Env(); defer { env.teardown() }
        let a = try env.file("Library/Caches/ms-playwright/StorageLensTest-w/a.bin", String(repeating: "z", count: 10_000))
        let c = env.cleaner(inUse: FakeInUse(names: ["Zed", "Alpha"]))
                let plan = c.plan([CleanupSelection(path: (a as NSString).deletingLastPathComponent)])
        let w = try #require(plan.items.first).warnings
        #expect(w.contains(Cleaner.trashNotice))
        #expect(w.contains { $0.contains("검토가 필요") })
        #expect(w.contains { $0.contains("Zed, Alpha") && $0.contains("앱 종료") })
        #expect(plan.items[0].sizeBytes > 0)
        #expect(plan.items[0].inode != 0)
    }

    // MARK: - 만료 / 교체

    @Test func expiredPlanRejectedWholesale() async throws {
        let env = try Env(); defer { env.teardown() }
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let f = try env.file("Library/Caches/StorageLensTest-exp/a")
        let c = env.cleaner(clock: clock)
        let plan = c.plan([CleanupSelection(path: (f as NSString).deletingLastPathComponent)])
        #expect(plan.items.count == 1)
        clock.advance(CleanupPlan.validityInterval)
        let r = await c.execute(plan)
        #expect(r.planExpired)
        #expect(r.outcomes.allSatisfy { $0.status == .skipped })
        #expect(FileManager.default.fileExists(atPath: f))
        #expect(c.journal.entries().isEmpty)
    }

    @Test func notYetExpiredAt599() {
        let p = CleanupPlan(createdAt: Date(timeIntervalSince1970: 1000), items: [])
        #expect(!p.isExpired(at: Date(timeIntervalSince1970: 1599)))
        #expect(p.isExpired(at: Date(timeIntervalSince1970: 1600)))
    }

    @Test func replacedTargetIsSkipped() async throws {
        let env = try Env(); defer { env.teardown() }
        let dir = try env.mkdir("Library/Caches/StorageLensTest-swap")
        try env.file("Library/Caches/StorageLensTest-swap/a")
        // inode 재사용 가능성을 줄이기 위해 다른 항목을 먼저 만들어 둔 뒤 교체
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: dir)])
        let oldInode = try #require(plan.items.first).inode
        // 삭제 후 같은 이름 재생성 (시험 정리 코드: 임시 홈 안)
        let hold = try env.mkdir("Library/Caches/hold-\(UUID().uuidString)")   // 새 inode 할당 유도
        try FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let newInode = try SystemFileSystem().attributes(at: URL(fileURLWithPath: dir)).inode
        _ = hold
        try #require(newInode != oldInode, "파일시스템이 inode를 재사용함 - 테스트 전제 불성립")
        let r = await c.execute(plan)
        #expect(r.outcomes.first?.status == .skipped)
        #expect(r.outcomes.first?.reason?.contains("inode") == true)
        #expect(FileManager.default.fileExists(atPath: dir))
        #expect(c.journal.entries().isEmpty)
    }

    @Test func targetBecomesProtectedSymlinkIsSkipped() async throws {
        let env = try Env(); defer { env.teardown() }
        let dir = try env.mkdir("Library/Caches/StorageLensTest-link")
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: dir)])
        try FileManager.default.removeItem(atPath: dir)
        try FileManager.default.createSymbolicLink(atPath: dir, withDestinationPath: env.p("Documents"))
        let r = await c.execute(plan)
        #expect(r.outcomes.first?.status == .skipped)
        #expect(FileManager.default.fileExists(atPath: env.p("Documents")))
    }

    // MARK: - 실제 trash + 저널 + undo

    @Test func trashJournalAndUndo() async throws {
        let env = try Env(); defer { env.teardown() }
        let name = "StorageLensTest-\(UUID().uuidString)"
        let dir = try env.mkdir("Library/Caches/\(name)")
        try env.file("Library/Caches/\(name)/data.bin", String(repeating: "q", count: 50_000))
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: dir)])
        #expect(plan.items.count == 1)
        let r = await c.execute(plan)
        let out = try #require(r.outcomes.first)
        if let t = out.trashedPath { env.trashed.append(t) }
        #expect(out.status == .succeeded, "\(out.reason ?? "")")
        #expect(!FileManager.default.fileExists(atPath: dir))
        let trashPath = try #require(out.trashedPath)
        #expect(FileManager.default.fileExists(atPath: trashPath))

        let entries = c.journal.entries()
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.originalPath == dir && e.trashPath == trashPath && e.method == "trash" && e.result == "success")
        #expect(e.sizeBytes == plan.items[0].sizeBytes)

        let (can, why) = c.canUndo(e)
        #expect(can && why == nil)
        let u = c.undo(e)
        #expect(u.success, "\(u.reason ?? "")")
        #expect(FileManager.default.fileExists(atPath: dir + "/data.bin"))
        #expect(!FileManager.default.fileExists(atPath: trashPath))
        let all = c.journal.entries()
        #expect(all.count == 2 && all[1].method == "undo" && all[1].result == "success")
        // 두 번째 되돌리기는 불가
        #expect(c.undo(e).success == false)
    }

    @Test func undoBlockedConditions() async throws {
        let env = try Env(); defer { env.teardown() }
        let c = env.cleaner()
        func run(_ name: String) async throws -> (JournalEntry, String) {
            let dir = try env.mkdir("Library/Caches/\(name)")
            try env.file("Library/Caches/\(name)/f")
            let r = await c.execute(c.plan([CleanupSelection(path: dir)]))
            let out = try #require(r.outcomes.first)
            if let t = out.trashedPath { env.trashed.append(t) }
            #expect(out.status == .succeeded)
            return (c.journal.entries().last { $0.originalPath == dir }!, dir)
        }
        // 1) 휴지통 경로가 없어짐
        let (e1, _) = try await run("StorageLensTest-u1-\(UUID().uuidString)")
        try FileManager.default.removeItem(atPath: e1.trashPath!)
        var res = c.canUndo(e1)
        #expect(!res.0 && res.1?.contains("휴지통") == true)
        // 2) 원래 경로에 이미 항목
        let (e2, d2) = try await run("StorageLensTest-u2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: d2, withIntermediateDirectories: true)
        res = c.canUndo(e2)
        #expect(!res.0 && res.1?.contains("이미") == true)
        #expect(c.undo(e2).success == false)
        // 3) 부모 폴더가 없음 (가짜 기록: 휴지통 경로는 존재하는 것으로)
        let (e3, d3) = try await run("StorageLensTest-u3-\(UUID().uuidString)")
        var gone = e3
        gone.originalPath = env.p("NoSuchParent-\(UUID().uuidString)/child")
        res = c.canUndo(gone)
        #expect(!res.0 && res.1?.contains("원래 폴더") == true)
        _ = d3
        // 4) 휴지통 경로가 아닌 기록 / trash 아닌 기록
        var bad = e3; bad.trashPath = env.p("Documents/x")
        #expect(!c.canUndo(bad).0)
        var cmd = e3; cmd.method = "command"
        #expect(!c.canUndo(cmd).0)
    }

    @Test func journalRoundTripAndAppend() throws {
        let env = try Env(); defer { env.teardown() }
        let j = Journal(fileURL: env.journalURL)
        #expect(j.entries().isEmpty)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try j.append(JournalEntry(timestamp: t, originalPath: "/a", trashPath: "/t", sizeBytes: 5, method: "trash", result: "success"))
        try j.append(JournalEntry(timestamp: t, originalPath: "/b", trashPath: nil, sizeBytes: 0, method: "command", result: "failed", detail: "x"))
        let e = j.entries()
        #expect(e.count == 2 && e[0].originalPath == "/a" && e[1].detail == "x" && e[0].timestamp == t)
        // 손상된 줄은 건너뜀
        let h = try FileHandle(forWritingTo: env.journalURL)
        try h.seekToEnd(); try h.write(contentsOf: Data("not json\n".utf8)); try h.close()
        #expect(j.entries().count == 2)
    }

    // MARK: - command

    private func cmdMatch(_ id: String, tool: String, args: [String], patterns: [String]) -> CatalogMatch {
        match(entry(id, method: .command, command: CatalogCommand(tool: tool, args: args), patterns: patterns))
    }

    @Test func commandRunsFakeToolWithoutShellAndMeasuresSize() async throws {
        let env = try Env(); defer { env.teardown() }
        let blob = try env.file(".cache/uv/blob.bin", String(repeating: "u", count: 100_000))
        let mark = env.root.appendingPathComponent("marker.txt").path
        try env.script("uv", "echo \"$@\" > '\(mark)'\nrm -f '\(blob)'")
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: env.p(".cache/uv"),
                                            match: cmdMatch("uv", tool: "uv", args: ["cache", "clean"], patterns: ["~/.cache/uv"]))])
        let item = try #require(plan.items.first)
        #expect(item.method == .command && item.toolPath == env.bin.path + "/uv")
        #expect(!item.warnings.contains(Cleaner.trashNotice))
        let r = await c.execute(plan)
        let out = try #require(r.outcomes.first)
        #expect(out.status == .succeeded, "\(out.reason ?? "")")
        #expect(try String(contentsOfFile: mark, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "cache clean")
        #expect(out.freedBytes > 0 && out.freedBytes <= item.sizeBytes)
        #expect((out.sizeAfterBytes ?? .max) < item.sizeBytes)
        let j = try #require(c.journal.entries().first)
        #expect(j.method == "command" && j.result == "success" && j.sizeBytes == out.freedBytes)
    }

    @Test func virtualCommandItem() async throws {
        let env = try Env(); defer { env.teardown() }
        let mark = env.root.appendingPathComponent("sim.txt").path
        try env.script("xcrun", "echo \"$@\" > '\(mark)'")
        let c = env.cleaner()
        let m = cmdMatch("xcode-sim-unavailable", tool: "xcrun", args: ["simctl", "delete", "unavailable"], patterns: [])
        let plan = c.plan([CleanupSelection(virtual: m)])
        let item = try #require(plan.items.first)
        #expect(item.isVirtual && item.sizeBytes == 0)
        let r = await c.execute(plan)
        #expect(r.outcomes.first?.status == .succeeded)
        #expect(try String(contentsOfFile: mark, encoding: .utf8).contains("simctl delete unavailable"))
        // 가상 항목이 trash 이거나 never 면 거부
        let bad = c.plan([CleanupSelection(virtual: match(entry("v", method: .trash, patterns: []))),
                          CleanupSelection(virtual: match(entry("n", safety: .discouraged, method: .command,
                                                                command: CatalogCommand(tool: "xcrun"), patterns: [])))])
        #expect(bad.items.isEmpty && bad.rejected.count == 2)
    }

    @Test func commandToolMissingRejected() throws {
        let env = try Env(); defer { env.teardown() }
        let plan = env.cleaner().plan([CleanupSelection(path: env.p(".cache/uv"),
                                                        match: cmdMatch("uv", tool: "uv", args: [], patterns: ["~/.cache/uv"]))])
        #expect(plan.items.isEmpty)
        #expect(plan.rejected.first?.reason == "도구 없음")
    }

    @Test func commandNonZeroExitIsFailure() async throws {
        let env = try Env(); defer { env.teardown() }
        try env.script("uv", "exit 3")
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: env.p(".cache/uv"),
                                            match: cmdMatch("uv", tool: "uv", args: [], patterns: ["~/.cache/uv"]))])
        let out = try #require(await c.execute(plan).outcomes.first)
        #expect(out.status == .failed && out.reason?.contains("3") == true)
        #expect(c.journal.entries().first?.result == "failed")
    }

    @Test func commandTimeoutTerminates() async throws {
        let env = try Env(); defer { env.teardown() }
        try env.script("uv", "exec sleep 30")
        let c = env.cleaner(timeout: 1)
        let plan = c.plan([CleanupSelection(path: env.p(".cache/uv"),
                                            match: cmdMatch("uv", tool: "uv", args: [], patterns: ["~/.cache/uv"]))])
        let start = Date()
        let out = try #require(await c.execute(plan).outcomes.first)
        #expect(Date().timeIntervalSince(start) < 15)
        #expect(out.status == .failed && out.reason?.contains("시간 초과") == true)
    }

    @Test func commandToolSwappedAfterPlanIsSkipped() async throws {
        let env = try Env(); defer { env.teardown() }
        try env.script("uv", "exit 0")
        let c = env.cleaner()
        let plan = c.plan([CleanupSelection(path: env.p(".cache/uv"),
                                            match: cmdMatch("uv", tool: "uv", args: [], patterns: ["~/.cache/uv"]))])
        try FileManager.default.removeItem(atPath: env.bin.appendingPathComponent("uv").path)
        let out = try #require(await c.execute(plan).outcomes.first)
        #expect(out.status == .skipped)
    }

    // MARK: - icloudEvict

    @Test func icloudEvictWalksFilesAndReportsPendingUploads() async throws {
        let env = try Env(); defer { env.teardown() }
        try env.file("Library/Mobile Documents/com~apple~CloudDocs/a.txt")
        try env.file("Library/Mobile Documents/com~apple~CloudDocs/sub/b.txt")
        try env.file("Library/Mobile Documents/com~apple~CloudDocs/sub/pending.txt")
        let outside = env.root.appendingPathComponent("outside.txt")
        try "o".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: env.p("Library/Mobile Documents/link.txt"),
                                                   withDestinationPath: outside.path)
        let fs = RecordingFS(failNames: ["pending.txt"])
        let c = env.cleaner(fs: fs)
        let m = match(entry("icloud-local", safety: .review, method: .icloudEvict))
        let plan = c.plan([CleanupSelection(path: env.p("Library/Mobile Documents"), match: m)])
        #expect(plan.items.count == 1)
        let out = try #require(await c.execute(plan).outcomes.first)
        #expect(out.status == .partial)
        #expect(out.failures.count == 1 && out.failures[0].path.hasSuffix("pending.txt") && out.failures[0].reason.contains("업로드 대기"))
        #expect(Set(fs.evicted.map { ($0 as NSString).lastPathComponent }) == ["a.txt", "b.txt"])
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(c.journal.entries().first?.method == "icloudEvict")
    }

    // MARK: - 하드 가드

    @Test func planHasNoPublicInitDocumentation() {
        // CleanupPlan.init / CleanupPlanItem.init 은 internal. 외부 모듈은 컴파일 불가 (위 파일 헤더 주석 참고).
        #expect(CleanupPlan.validityInterval == 600)
    }
}
