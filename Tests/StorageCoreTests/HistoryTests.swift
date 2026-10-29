import XCTest
@testable import StorageCore

final class HistoryTests: XCTestCase {
    private func tmp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
    }
    private func dir(_ name: String, _ size: Int64, _ kids: [Node] = []) -> Node {
        Node(name: name, isDirectory: true, allocatedSize: size, logicalSize: size, inode: 1, devID: 1,
             modified: Date(), children: kids)
    }
    private func summary(_ root: String, _ t: TimeInterval, _ folders: [(String, Int64)] = [], cats: [String: Int64] = [:]) -> ScanSummary {
        ScanSummary(scannedAt: Date(timeIntervalSince1970: t), rootPath: root, categoryTotals: cats,
                    topFolders: folders.map { ScanSummary.FolderSize(path: $0.0, allocatedSize: $0.1) })
    }

    func testKeeps30() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = HistoryStore(directory: d)
        for i in 0..<31 { try s.save(summary("/r", 1000 + Double(i))) }
        let all = s.all()
        XCTAssertEqual(all.count, 30)
        XCTAssertEqual(all.first?.scannedAt, Date(timeIntervalSince1970: 1030))
        XCTAssertEqual(all.last?.scannedAt, Date(timeIntervalSince1970: 1001))
        let files = try FileManager.default.contentsOfDirectory(atPath: d.path)
        XCTAssertEqual(files.count, 30)
        XCTAssertFalse(files.contains { $0.contains(":") })
    }

    func testLatestSameRootOnly() throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = HistoryStore(directory: d)
        try s.save(summary("/a", 100)); try s.save(summary("/b", 200)); try s.save(summary("/a", 150))
        let r = s.latest(rootPath: "/a", before: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(r?.scannedAt, Date(timeIntervalSince1970: 150))
        XCTAssertEqual(s.latest(rootPath: "/a", before: Date(timeIntervalSince1970: 150))?.scannedAt,
                       Date(timeIntervalSince1970: 100))
        XCTAssertNil(s.latest(rootPath: "/c", before: Date(timeIntervalSince1970: 300)))
    }

    func testMakeDepthLimit() {
        let deep = dir("d3", 1, [dir("d4", 1)])
        let root = dir("root", 100, [dir("d1", 50, [dir("d2", 20, [deep])])])
        let res = ScanResult(rootPath: "/r", root: root, skipped: [], startedAt: Date(), finishedAt: Date())
        let s = ScanSummary.make(from: res, categoryTotals: ["x": 5], scannedAt: Date())
        let paths = Set(s.topFolders.map(\.path))
        XCTAssertEqual(paths, ["/r", "/r/d1", "/r/d1/d2", "/r/d1/d2/d3"])
        XCTAssertEqual(s.topFolders.first?.path, "/r")
        XCTAssertEqual(s.categoryTotals, ["x": 5])
    }

    func testMakeTop200() {
        let kids = (0..<300).map { dir("k\($0)", Int64($0 + 1)) }
        let res = ScanResult(rootPath: "/r", root: dir("r", 10_000, kids), skipped: [], startedAt: Date(), finishedAt: Date())
        let s = ScanSummary.make(from: res, categoryTotals: [:], scannedAt: Date())
        XCTAssertEqual(s.topFolders.count, 200)
        XCTAssertEqual(s.topFolders.map(\.allocatedSize), s.topFolders.map(\.allocatedSize).sorted(by: >))
        XCTAssertEqual(s.topFolders.last?.allocatedSize, 102)
    }

    func testDiff() {
        let p = summary("/r", 1, [("/a", 100), ("/b", 50), ("/gone", 30)], cats: ["c1": 10])
        let c = summary("/r", 2, [("/a", 110), ("/b", 10), ("/new", 70)], cats: ["c1": 5, "c2": 8])
        let ch = HistoryDiff.topChanges(previous: p, current: c)
        XCTAssertEqual(ch.map(\.path), ["/new", "/b", "/gone", "/a"])
        XCTAssertEqual(ch[0].delta, 70)
        XCTAssertEqual(ch[2].current, 0)
        XCTAssertEqual(HistoryDiff.topChanges(previous: p, current: c, limit: 2).count, 2)
        let cc = HistoryDiff.categoryChanges(previous: p, current: c)
        XCTAssertEqual(cc.map(\.path), ["c2", "c1"])
    }
}
