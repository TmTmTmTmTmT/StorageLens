import Foundation
import Testing
@testable import StorageCore

private struct FakeLister: ProcessLister {
    let records: [OpenFileRecord]
    func openFiles() -> [OpenFileRecord] { records }
}

@Suite struct InUseTests {
    func index() -> InUseIndex {
        InUseIndex.snapshot(lister: FakeLister(records: [
            .init(pid: 1, processName: "Zed", path: "/a/b/file.txt"),
            .init(pid: 2, processName: "Alpha", path: "/a/b/c/d.db"),
            .init(pid: 3, processName: "Other", path: "/a/bc/x"),
            .init(pid: 4, processName: "Alpha", path: "/a/b-x/y"),
            .init(pid: 5, processName: "Priv", path: "/private/var/tmp/z"),
        ]))
    }

    @Test func exactMatch() {
        #expect(index().processes(usingPathPrefix: "/a/b/file.txt") == ["Zed"])
    }
    @Test func prefixMatchSortedDedup() {
        #expect(index().processes(usingPathPrefix: "/a/b") == ["Alpha", "Zed"])
        #expect(index().processes(usingPathPrefix: "/a/b/") == ["Alpha", "Zed"])
    }
    @Test func boundary() {
        #expect(index().processes(usingPathPrefix: "/a/bc") == ["Other"])
        #expect(index().processes(usingPathPrefix: "/a/b/fil").isEmpty)
        #expect(index().processes(usingPathPrefix: "/nope").isEmpty)
    }
    @Test func rootMatchesAll() {
        #expect(index().processes(usingPathPrefix: "/") == ["Alpha", "Other", "Priv", "Zed"])
    }
    @Test func privateAlias() {
        #expect(index().processes(usingPathPrefix: "/var/tmp") == ["Priv"])
        #expect(index().processes(usingPathPrefix: "/private/var/tmp/z") == ["Priv"])
    }

    @Test func realSystemSeesOwnOpenFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("held.bin")
        try Data([1, 2, 3]).write(to: file)
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }

        let start = Date()
        let records = SystemProcessLister().openFiles()
        let elapsed = Date().timeIntervalSince(start)
        print("InUse openFiles: \(records.count) records in \(elapsed)s")
        let me = getpid()
        #expect(records.contains { $0.pid == me })
        let idx = InUseIndex(records: records)
        #expect(!idx.processes(usingPathPrefix: file.path).isEmpty)
        #expect(!idx.processes(usingPathPrefix: dir.path).isEmpty)
    }
}
