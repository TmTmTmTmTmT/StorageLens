import Testing
import Foundation
@testable import StorageCore

@Suite struct SessionTests {
    static let home = "/Users/t"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let old = Date(timeIntervalSince1970: 1_800_000_000 - 200 * 86400)

    static func dir(_ name: String, _ children: [Node] = [], modified: Date = now) -> Node {
        Node(name: name, isDirectory: true, allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
             logicalSize: 0, inode: 1, devID: 1, modified: modified, children: children)
    }
    static func file(_ name: String, _ size: Int64, modified: Date = now) -> Node {
        Node(name: name, isDirectory: false, allocatedSize: size, logicalSize: size, inode: 2, devID: 1, modified: modified)
    }

    static func matcher() throws -> CatalogMatcher {
        let cat = try TestSupport.loadCatalog()
        return CatalogMatcher(catalog: cat, home: home, clock: FixedClock(now: now), toolResolver: { _ in nil })
    }

    static func tree() -> Node {
        dir("/", [
            dir("Applications", [file("big.bin", 1000)]),
            dir("Users", [dir("t", [
                dir("Library", [
                    dir("Caches", [dir("Foo", [file("a", 100)]), dir("pip", [file("b", 40)]), dir("com.apple.x", [file("c", 50)])]),
                    dir("Application Support", [dir("Bar", [file("d", 70)])]),
                ]),
                dir(".cache", [dir("uv", [file("e", 30)])]),
                dir("Downloads", [file("old.zip", 10, modified: old), file("new.zip", 5)]),
                dir("Projects", [file("p", 9)]),
            ])]),
        ])
    }

    @Test func categoryTotalsMatchesAndStops() throws {
        let t = CategoryTotals.compute(root: Self.tree(), logicalRootPath: "/", matcher: try Self.matcher(), home: Self.home)
        #expect(t["user-caches"] == 100)
        #expect(t["pip"] == 40)
        #expect(t["apple-caches"] == 50)
        #expect(t["app-support"] == 70)
        #expect(t["uv"] == 30)
        #expect(t["downloads-old"] == 10)           // new.zip은 90일 미만
        let total = Self.tree().allocatedSize
        let matched = t.filter { $0.key != "other" }.values.reduce(0, +)
        #expect(t["other"] == total - matched)
        #expect(t["other"] == Int64(1000 + 5 + 9))
    }

    @Test func categoryTotalsPrefersMoreSpecificChildPattern() throws {
        let root = Self.dir("/", [Self.dir("Users", [Self.dir("t", [Self.dir("Library", [
            Self.dir("Caches", [Self.dir("Homebrew", [
                Self.dir("downloads", [Self.file("a", 100)]),
                Self.dir("other", [Self.file("b", 50)]),
            ])]),
        ])])]), Self.file("z", 7)])
        let t = CategoryTotals.compute(root: root, logicalRootPath: "/", matcher: try Self.matcher(), home: Self.home)
        #expect(t["homebrew"] == 100)
        #expect(t["user-caches"] == 50)
        #expect(t["other"] == 7)
        #expect(t.values.reduce(0, +) == root.allocatedSize)
    }

    @Test func categoryTotalsWithSubRoot() throws {
        let root = Self.dir("/System/Volumes/Data/Users/t/Library/Caches", [Self.dir("Foo", [Self.file("a", 100)])])
        let logical = ScanOutcome.logicalPath("/System/Volumes/Data/Users/t/Library/Caches")
        #expect(logical == "/Users/t/Library/Caches")
        let t = CategoryTotals.compute(root: root, logicalRootPath: logical, matcher: try Self.matcher(), home: Self.home)
        #expect(t["user-caches"] == 100)
        #expect(t["other"] == nil)
    }

    @Test func orphanUsesAttribution() throws {
        let t = CategoryTotals.compute(root: Self.tree(), logicalRootPath: "/", matcher: try Self.matcher(), home: Self.home,
                                       attribute: { p in
            p.hasSuffix("Caches/Foo") ? Attribution(appName: "x", confidence: .inferred, rule: "t", isOrphanSuspect: true) : nil
        })
        #expect(t["orphan"] == 100)
        #expect(t["user-caches"] == nil)
    }

    @Test func logicalPath() {
        #expect(ScanOutcome.logicalPath("/System/Volumes/Data") == "/")
        #expect(ScanOutcome.logicalPath("/System/Volumes/DataX") == "/System/Volumes/DataX")
        #expect(ScanOutcome.logicalPath("/Users/t") == "/Users/t")
    }

    @Test func volumeInfo() {
        let v = VolumeInfo(total: 1000, available: 100, availableForImportantUsage: 250)
        #expect(v.purgeable == 150)
        #expect(v.used == 750)
        #expect(v.used + v.purgeable + v.available == v.total)
        #expect(VolumeInfo(total: 10, available: 5, availableForImportantUsage: 3).purgeable == 0)
    }

    @Test func sunburstGroupsSmallIntoOther() {
        let focus = Self.dir("r", [Self.file("big", 900), Self.file("mid", 90), Self.file("tiny", 3), Self.file("tiny2", 2)])
        let arcs = SunburstLayout.arcs(focus: focus, focusPath: "/r")
        #expect(arcs.map(\.name) == ["big", "mid", "기타"])
        #expect(arcs.last?.isOther == true)
        #expect(arcs.last?.size == 5)
        #expect(abs(arcs.last!.end - 1.0) < 1e-9)
    }

    @Test func sunburstDepthLimit() {
        var n = Self.dir("d5", [Self.file("f", 100)])
        for i in stride(from: 4, through: 1, by: -1) { n = Self.dir("d\(i)", [n]) }
        let arcs = SunburstLayout.arcs(focus: Self.dir("root", [n]), focusPath: "/root")
        #expect(arcs.map(\.depth).max() == 4)
    }

    @Test func nodeLookupAndBreadcrumb() {
        let root = Self.tree()
        #expect(ScanOutcome.find(root: root, rootPath: "/", path: "/Users/t/.cache/uv")?.allocatedSize == 30)
        #expect(ScanOutcome.find(root: root, rootPath: "/", path: "/nope") == nil)
        #expect(ScanOutcome.find(root: root, rootPath: "/Users", path: "/Users/t") == nil)
    }

    @Test func cleanupAvailabilityRules() throws {
        let m = try Self.matcher()
        func av(_ p: String) -> CleanupAvailability { CleanupAvailability.from(match: m.match(path: p), path: p) }
        let disc = av("\(Self.home)/Library/Application Support/Bar")
        #expect(disc.enabled && disc.isDiscouraged && !disc.isBatchable && disc.method == .trash)
        let safe = av("\(Self.home)/Library/Caches/Foo")
        #expect(safe.enabled && safe.isBatchable)
        let review = av("\(Self.home)/Library/Caches/com.apple.x")
        #expect(review.enabled && !review.isBatchable && review.safety == .review)
        let outside = av("\(Self.home)/Projects")
        #expect(outside.enabled && outside.safety == nil && !outside.isBatchable)
        // 도구 없음 (toolResolver가 항상 nil)
        let uv = av("\(Self.home)/.cache/uv")
        #expect(!uv.enabled && uv.reason == "도구 없음")
        let virtual = CleanupAvailability.from(match: m.resolve(try #require(m.catalog.entry(id: "xcode-sim-unavailable"))), path: "v")
        #expect(!virtual.enabled && virtual.reason == "도구 없음")
    }

    @Test func sessionMakesCleanerAndJournalRowsNewestFirst() throws {
        let tmp = try SystemFileSystem().realPath(of: URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("StorageLensTest-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/X"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cat = try TestSupport.loadCatalog()
        let session = StorageSession(home: home, rules: AttributionRules(), catalog: cat,
                                     historyDirectory: tmp.appendingPathComponent("h"))
        let cleaner = session.makeCleaner(outcome: nil)
        // 보호 경로(~/Library/Application Support 자체)는 호출자 매치 없이도 거부
        let plan = cleaner.plan([CleanupSelection(path: home.appendingPathComponent("Library/Application Support").path)])
        #expect(plan.items.isEmpty && plan.rejected.count == 1, "\(plan.items) \(plan.rejected)")
        #expect(cleaner.journal.fileURL == Journal.defaultURL(home: home))
        try cleaner.journal.append(JournalEntry(timestamp: Self.now, originalPath: "/a", trashPath: nil, sizeBytes: 1, method: "command", result: "success"))
        try cleaner.journal.append(JournalEntry(timestamp: Self.now, originalPath: "/b", trashPath: nil, sizeBytes: 2, method: "trash", result: "success"))
        let rows = StorageSession.journalRows(cleaner: cleaner)
        #expect(rows.map(\.entry.originalPath) == ["/b", "/a"])
        #expect(rows.allSatisfy { !$0.canUndo && $0.undoReason != nil })
    }

    @Test func missingResourcesGiveEmpty() {
        let (r, c) = StorageSession.loadResources(bundle: Bundle(for: BundleToken.self))
        #expect(r.pathRules.isEmpty)
        #expect(c.entries.isEmpty)
    }
}

private final class BundleToken {}
