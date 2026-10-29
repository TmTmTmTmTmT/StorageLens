import Testing
import Foundation
@testable import StorageCore

struct ToolLocatorTests {
    private func tmpDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        chmod(d.path, 0o755)
        return d
    }
    private func tool(_ dir: URL, _ name: String, mode: mode_t = 0o755) throws {
        let f = dir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
        chmod(f.path, mode)
    }

    @Test func groupWritableFakeToolIgnored() throws {
        let bad = try tmpDir(), good = try tmpDir()
        defer { try? FileManager.default.removeItem(at: bad); try? FileManager.default.removeItem(at: good) }
        try tool(bad, "mytool", mode: 0o775)
        try tool(good, "mytool")
        let l = ToolLocator(candidateDirectories: [bad.path, good.path])
        #expect(l.locate("mytool") == good.path + "/mytool")
        let onlyBad = ToolLocator(candidateDirectories: [bad.path])
        #expect(onlyBad.locate("mytool") == nil)
    }

    @Test func worldWritableOrGroupWritableDirectoryIgnored() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        try tool(d, "mytool")
        chmod(d.path, 0o775)
        #expect(ToolLocator(candidateDirectories: [d.path]).locate("mytool") == nil)
        chmod(d.path, 0o755)
        #expect(ToolLocator(candidateDirectories: [d.path]).locate("mytool") != nil)
    }

    @Test func xcrunAlwaysSystemPath() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        try tool(d, "xcrun")
        let l = ToolLocator(candidateDirectories: [d.path, "/usr/bin"])
        #expect(l.locate("xcrun") == "/usr/bin/xcrun")
        #expect(l.locateDetailed("xcrun")?.isNonStandard == false)
        // 주입된 시스템 도구 폴더가 비어 있으면 후보에 있어도 nil
        let empty = try tmpDir(); defer { try? FileManager.default.removeItem(at: empty) }
        #expect(ToolLocator(candidateDirectories: [d.path], systemToolDirectory: empty.path).locate("xcrun") == nil)
    }

    @Test func nonStandardFlag() throws {
        let d = try tmpDir(); defer { try? FileManager.default.removeItem(at: d) }
        try tool(d, "mytool")
        let r = ToolLocator(candidateDirectories: [d.path]).locateDetailed("mytool")
        #expect(r == LocatedTool(path: d.path + "/mytool", isNonStandard: true))
        // 표준 디렉터리의 도구는 플래그 false
        if let sh = ToolLocator(candidateDirectories: ["/usr/bin"]).locateDetailed("make") {
            #expect(sh.isNonStandard == false)
        }
        #expect(ToolLocator(candidateDirectories: [d.path]).locateDetailed("nope") == nil)
    }
}

struct ToolLocatorTrustRuleTests {
    @Test func adminGroupWriteRule() {
        let me: uid_t = 501
        func ok(_ o: uid_t, _ g: gid_t, _ m: mode_t, admin: Bool) -> Bool {
            ToolLocator.isTrustedMode(owner: o, group: g, mode: m, currentUID: me, allowAdminGroupWrite: admin)
        }
        #expect(ok(me, 80, 0o775, admin: true))
        #expect(ok(0, 80, 0o775, admin: true))
        #expect(!ok(me, 80, 0o775, admin: false))
        #expect(!ok(me, 20, 0o775, admin: true))
        #expect(!ok(me, 80, 0o757, admin: true))
        #expect(!ok(999, 80, 0o755, admin: true))
        #expect(ok(me, 20, 0o755, admin: false))
    }
}
