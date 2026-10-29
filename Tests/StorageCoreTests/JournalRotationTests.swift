import Testing
import Foundation
@testable import StorageCore

// F11-10 저널 회전 (PLAN §8.2 v1.2). 임시 디렉터리만 사용.

private func tmpJournal() -> (URL, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("StorageLensTest-jr-\(UUID().uuidString)")
    return (root, root.appendingPathComponent("journal.jsonl"))
}

private func entry(_ i: Int, trash: String? = nil) -> JournalEntry {
    JournalEntry(timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)), originalPath: "/e\(i)",
                 trashPath: trash, sizeBytes: Int64(i), method: "trash", result: "success",
                 detail: String(repeating: "d", count: 100))
}

private func lineCount(_ u: URL) -> Int {
    guard let s = try? String(contentsOf: u, encoding: .utf8) else { return -1 }
    return s.split(separator: "\n").count
}

@Suite struct JournalRotationTests {
    @Test func rotatesWhenOverThresholdAndMergesInOrder() throws {
        let (root, url) = tmpJournal(); defer { try? FileManager.default.removeItem(at: root) }
        let j = Journal(fileURL: url, maxBytes: 1000)
        for i in 0..<20 { try j.append(entry(i)) }
        #expect(FileManager.default.fileExists(atPath: j.rotatedURL.path))
        #expect(j.rotatedURL.lastPathComponent == "journal.1.jsonl")
        #expect(lineCount(url) > 0)
        let r = j.read()
        // 가장 오래된 세대가 폐기되지 않은 범위에서 시간순·연속
        let idx = r.entries.map { Int($0.sizeBytes) }
        #expect(idx == Array((20 - idx.count)..<20))
        #expect(r.corruptLineCount == 0)
    }

    @Test func noRotationBelowThreshold() throws {
        let (root, url) = tmpJournal(); defer { try? FileManager.default.removeItem(at: root) }
        let j = Journal(fileURL: url, maxBytes: 1_000_000)
        for i in 0..<10 { try j.append(entry(i)) }
        #expect(!FileManager.default.fileExists(atPath: j.rotatedURL.path))
        #expect(j.read().entries.count == 10)
    }

    @Test func secondRotationDropsOldestGeneration() throws {
        let (root, url) = tmpJournal(); defer { try? FileManager.default.removeItem(at: root) }
        let j = Journal(fileURL: url, maxBytes: 600)
        for i in 0..<60 { try j.append(entry(i)) }
        let got = j.read().entries.map { Int($0.sizeBytes) }
        #expect(got.last == 59)
        #expect(got.first! > 0)          // 가장 오래된 항목은 폐기됨
        #expect(got.count < 60)
        #expect(got == Array((60 - got.count)..<60))
    }

    @Test func corruptLinesSummedAcrossFiles() throws {
        let (root, url) = tmpJournal(); defer { try? FileManager.default.removeItem(at: root) }
        let j = Journal(fileURL: url, maxBytes: 100_000)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("garbage\n".utf8).write(to: j.rotatedURL)
        try j.append(entry(1))
        try Data("more garbage\n".utf8).write(to: url, options: []) // overwrite current with garbage
        try j.append(entry(2))
        let r = j.read()
        #expect(r.corruptLineCount == 2)
        #expect(r.entries.map(\.originalPath) == ["/e2"])
    }

    @Test func rotatedEntryStillJudgedForUndo() throws {
        let (root, url) = tmpJournal(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let m = CatalogMatcher(catalog: try TestSupport.loadCatalog(), home: home.path, toolResolver: { _ in nil })
        let j = Journal(fileURL: url, maxBytes: 1500)
        let c = Cleaner(home: home, matcher: m, toolLocator: ToolLocator(home: home, candidateDirectories: []), journal: j)
        let first = entry(0, trash: home.appendingPathComponent(".Trash/x").path)
        try j.append(first)
        for i in 1..<8 { try j.append(entry(i)) }
        #expect(FileManager.default.fileExists(atPath: j.rotatedURL.path))
        let load = StorageSession.journalLoad(cleaner: c)
        let rows = load.rows
        #expect(rows.count == 8 && load.corruptLineCount == 0)
        // 최신순, 첫 항목(회전 파일에 있음)이 마지막 행
        #expect(rows.first?.entry.originalPath == "/e7")
        let last = try #require(rows.last)
        #expect(last.entry.originalPath == "/e0")
        let (ok, why) = c.canUndo(first)
        #expect(last.canUndo == ok && last.undoReason == why)
        #expect(Set(rows.map(\.id)).count == 8)
    }

    @Test func concurrentAppendsAcrossRotationLoseNothing() throws {
        let (root, url) = tmpJournal(); defer { try? FileManager.default.removeItem(at: root) }
        // 회전 임계를 크게 잡아 1세대(.1)에 모두 남도록: 총량 < 2*임계 보장은 어려우므로 임계를 총량보다 크게 두되 1회 회전을 유발.
        let j1 = Journal(fileURL: url, maxBytes: 30_000), j2 = Journal(fileURL: url, maxBytes: 30_000)
        DispatchQueue.concurrentPerform(iterations: 4) { k in
            let j = k % 2 == 0 ? j1 : j2
            for i in 0..<40 { try? j.append(entry(k * 1000 + i)) }
        }
        #expect(FileManager.default.fileExists(atPath: j1.rotatedURL.path))
        let r = j1.read()
        #expect(r.corruptLineCount == 0)
        #expect(r.entries.count == 160)
        #expect(Set(r.entries.map(\.originalPath)).count == 160)
    }
}
