import Testing
import Foundation
@testable import StorageCore

@Suite struct PerfCoreTests {
    typealias T = AppDataTests

    private static func wide(_ n: Int, prefix: String = "f") -> Node {
        let kids = (0..<n).map { T.file("\(prefix)\($0)", Int64(1000 + ($0 * 7919) % 5000)) }
        return T.dir("/", [T.dir("big", kids)])
    }

    // MARK: 세대 토큰

    @Test func staleGenerationIsDiscarded() {
        var gate = GenerationGate()
        let g1 = gate.advance()
        #expect(gate.isCurrent(g1))
        let g2 = gate.advance()
        #expect(!gate.isCurrent(g1))
        #expect(gate.isCurrent(g2))
    }

    // MARK: LRU

    @Test func lruEvictsOldestAndTouchOnGet() {
        var c = LRUCache<String, Int>(capacity: 3)
        c.set("a", 1); c.set("b", 2); c.set("c", 3)
        #expect(c.get("a") == 1)          // a 가 최신이 됨
        c.set("d", 4)                      // b 제거
        #expect(c.get("b") == nil)
        #expect(c.keysOldestFirst == ["c", "a", "d"])
        #expect(c.count == 3)
    }

    @Test func rowsAreCachedPerPathAndSort() throws {
        let o = try T.outcome(tree: Self.wide(50))
        let a = o.rows(focusPath: "/big", sort: .size)
        #expect(o.derivedCache.cachedRows(RowsKey(path: "/big", sort: .size)) == a)
        #expect(o.derivedCache.cachedRows(RowsKey(path: "/big", sort: .modified)) == nil)
        #expect(o.rows(focusPath: "/big", sort: .size) == a)
        #expect(a.count == 50)
        #expect(zip(a, a.dropFirst()).allSatisfy { $0.size >= $1.size })
    }

    // MARK: 큰 폴더 요약

    @Test func hugeFolderIsTruncatedWithSummaryRow() throws {
        let o = try T.outcome(tree: Self.wide(6000))
        let rows = o.rows(focusPath: "/big", sort: .size)
        #expect(rows.count == ScanOutcome.rowKeepCount + 1)
        let s = try #require(rows.last)
        #expect(s.isOmittedSummary)
        #expect(s.name == "나머지 \(6000 - ScanOutcome.rowKeepCount)개")
        let total = rows.reduce(Int64(0)) { $0 + $1.size }
        #expect(total == o.node(at: "/big")!.allocatedSize)
        #expect(rows.filter(\.isOmittedSummary).count == 1)
    }

    @Test func smallFolderKeepsLegacySummaryRow() throws {
        var big = Self.wide(10)
        big.children[0].omittedFileCount = 3; big.children[0].omittedBytes = 30
        let o = try T.outcome(tree: big)
        let rows = o.rows(focusPath: "/big", sort: .size, truncateAbove: 5, keep: 2)
        #expect(rows.count == 3)   // truncated: 2 + summary
        let legacy = o.rows(focusPath: "/big", sort: .size)
        #expect(legacy.count == 11)
        #expect(legacy.last?.name == "작은 파일 3개")
    }

    @Test func cancelledRowsReturnEmptyAndAreNotCached() async throws {
        let o = try T.outcome(tree: Self.wide(3000))
        let t = Task.detached { () -> [NodeRow] in
            while !Task.isCancelled { await Task.yield() }
            return o.rows(focusPath: "/big", sort: .size)
        }
        t.cancel()
        let r = await t.value
        #expect(r.isEmpty)
        #expect(o.derivedCache.cachedRows(RowsKey(path: "/big", sort: .size)) == nil)
    }

    // MARK: 실경로 InUse

    @Test func realPathInUseMatchesResolvedQuery() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("sl-c2-\(UUID().uuidString)")
        try fm.createDirectory(at: base.appendingPathComponent("d/sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let real = base.resolvingSymlinksInPath().path   // 실경로 (/private/var -> 정규화에서 /var)
        let recs = [
            OpenFileRecord(pid: 1, processName: "alpha", path: real + "/d/sub/x.bin"),
            OpenFileRecord(pid: 2, processName: "beta", path: real + "/d/y"),
            OpenFileRecord(pid: 3, processName: "gamma", path: real + "/dd/z"),
        ]
        let idx = InUseIndex(records: recs)
        for q in [real, real + "/d", real + "/d/sub", real + "/d/sub/x.bin", real + "/dd", real + "/none", "/", "/Users"] {
            #expect(idx.processes(usingRealPath: q) == idx.processes(usingPathPrefix: q), "query \(q)")
        }
        #expect(idx.processes(usingRealPath: real + "/d") == ["alpha", "beta"])
    }

    @Test func outcomeRowsInUseSameAsResolvedVersion() throws {
        let recs = [OpenFileRecord(pid: 1, processName: "alpha", path: "/big/f3")]
        let o = try T.outcome(tree: Self.wide(20), records: recs)
        #expect(o.rootIsRealPath)
        for r in o.rows(focusPath: "/big", sort: .size) where !r.isOmittedSummary {
            #expect(r.inUseBy == o.inUse.processes(usingPathPrefix: r.path))
        }
        #expect(o.rows(focusPath: "/big", sort: .size).first { $0.name == "f3" }?.inUseBy == ["alpha"])
    }

    // MARK: 음성 캐시

    @Test func lookupCacheRemembersMisses() {
        let c = LookupCache<Int>(capacity: 4)
        var calls = 0
        #expect(c.value(for: "x", compute: { calls += 1; return nil }) == nil)
        #expect(c.value(for: "x", compute: { calls += 1; return 5 }) == nil)   // 음성 캐시: 재조회 없음
        #expect(calls == 1)
        #expect(c.value(for: "y", compute: { 7 }) == 7)
        #expect(c.value(for: "y", compute: { 8 }) == 7)
        for i in 0..<10 { c.store("k\(i)", i) }
        #expect(c.count == 4)
        #expect(c.peek("x") == nil)   // 오래된 항목 제거됨
    }

    // MARK: 선버스트

    @Test func sunburstFiltersBelowThresholdIntoOther() throws {
        let big = (0..<5).map { T.file("b\($0)", 1000) }
        let tiny = (0..<100).map { T.file("t\($0)", 1) }
        let tree = T.dir("/", big + tiny)
        let arcs = SunburstLayout.arcs(focus: tree, focusPath: "/")
        #expect(arcs.filter { !$0.isOther }.count == 5)
        let other = try #require(arcs.first { $0.isOther })
        #expect(other.size == 100)
        #expect(abs(arcs.last!.end - 1.0) < 1e-9)
        #expect(arcs.filter { !$0.isOther }.map(\.name) == ["b0", "b1", "b2", "b3", "b4"])  // 동률은 이름순
    }

    @Test func childMapLookupFindsNodes() throws {
        let o = try T.outcome(tree: Self.wide(600))
        #expect(o.node(at: "/big/f599")?.name == "f599")
        #expect(o.node(at: "/big/f0")?.name == "f0")
        #expect(o.node(at: "/big/nope") == nil)
        #expect(o.node(at: "/big/f1") == ScanOutcome.find(root: o.root, rootPath: "/", path: "/big/f1"))
    }

    // MARK: 측정 (SL_PERF 게이트)

    /// 이전 구현(전체 정렬 + 항목별 링크 해석 InUse)을 그대로 재현한 기준선.
    private static func legacyRows(_ o: ScanOutcome, _ path: String) -> Int {
        let focus = o.node(at: path)!
        var rows = focus.children.map { c -> NodeRow in
            let p = path == "/" ? "/" + c.name : path + "/" + c.name
            return NodeRow(id: p, name: c.name, path: p, isDirectory: c.isDirectory, size: c.allocatedSize,
                           modified: c.modified, isDataless: c.isDataless, attribution: o.attribution(forPath: p),
                           inUseBy: o.inUse.processes(usingPathPrefix: p), isOmittedSummary: false)
        }
        rows.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        return rows.count
    }

    private static func legacyArcs(_ node: Node, minFraction: Double = 0.005) -> Int {
        let total = node.allocatedSize
        let threshold = Int64(Double(total) * minFraction)
        var n = 0
        func go(_ nd: Node, depth: Int) {
            for c in nd.children.sorted(by: { $0.allocatedSize > $1.allocatedSize }) {
                guard c.allocatedSize > 0, c.allocatedSize >= threshold else { continue }
                n += 1
                if c.isDirectory, depth < 4 { go(c, depth: depth + 1) }
            }
        }
        go(node, depth: 1)
        return n
    }

    @Test func perfRowsAndArcs() throws {
        guard ProcessInfo.processInfo.environment["SL_PERF"] != nil else { return }
        var kids: [Node] = []
        for i in 0..<20_000 {
            if i % 20 == 0 {
                var sub: [Node] = []
                for j in 0..<30 { sub.append(T.file("g\(j)", Int64(100 + j))) }
                kids.append(T.dir("d\(i)", sub))
            } else {
                let sz: Int64 = Int64(1000 + (i * 7919) % 90_000)
                kids.append(T.file("f\(i)", sz))
            }
        }
        let o = try T.outcome(tree: T.dir("/", [T.dir("big", kids)]))
        func time(_ f: () -> Int) -> Double { let t = Date(); _ = f(); return Date().timeIntervalSince(t) * 1000 }
        let before = time { Self.legacyRows(o, "/big") } + time { Self.legacyArcs(o.node(at: "/big")!) }
        let after = time { o.rows(focusPath: "/big", sort: .size).count }
            + time { o.sunburst(focusPath: "/big").count }
        let cached = time { o.rows(focusPath: "/big", sort: .size).count }
        print("PERF-C2: children=20000 before_ms=\(String(format: "%.1f", before)) after_ms=\(String(format: "%.1f", after)) cachedRows_ms=\(String(format: "%.3f", cached))")
    }
}
