import Testing
import Foundation
@testable import StorageCore

private func find(_ node: Node, _ name: String) -> Node? {
    if node.name == name { return node }
    for c in node.children { if let f = find(c, name) { return f } }
    return nil
}

private func countNodes(_ n: Node) -> Int { 1 + n.children.reduce(0) { $0 + countNodes($1) } }

private func shell(_ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    try p.run(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}

private func realPathString(_ p: String) -> String {
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
}

@Suite struct ScanTests {
    /// 픽스처 생성 후 body 실행, 권한 복구 및 삭제 보장.
    private func withFixture(_ body: (URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("sl-scan-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer {
            chmod(base.appendingPathComponent("locked").path, 0o755)
            try? fm.removeItem(at: base)
        }
        // 일반 파일 (1MB)
        try Data(repeating: 0x41, count: 1_048_576).write(to: base.appendingPathComponent("plain.bin"))
        // 하드링크 쌍
        try Data(repeating: 0x42, count: 1_048_576).write(to: base.appendingPathComponent("hl1.bin"))
        try fm.linkItem(at: base.appendingPathComponent("hl1.bin"), to: base.appendingPathComponent("hl2.bin"))
        // clone
        try Data(repeating: 0x43, count: 1_048_576).write(to: base.appendingPathComponent("orig.bin"))
        try shell(["/bin/cp", "-c", base.appendingPathComponent("orig.bin").path,
                   base.appendingPathComponent("clone.bin").path])
        // sparse 1G
        let sparse = base.appendingPathComponent("sparse.bin")
        fm.createFile(atPath: sparse.path, contents: nil)
        let h = try FileHandle(forWritingTo: sparse)
        try h.truncate(atOffset: 1 << 30); try h.close()
        // 심볼릭 링크 (루프 포함)
        let sub = base.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: sub.appendingPathComponent("loop").path, withDestinationPath: "..")
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("selflink").path, withDestinationPath: ".")
        // 권한 없는 폴더
        let locked = base.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0x44, count: 4096).write(to: locked.appendingPathComponent("hidden.bin"))
        chmod(locked.path, 0o000)
        try await body(base)
    }

    @Test func fixtureScan() async throws {
        try await withFixture { base in
            let result = try await Scanner().scan(root: base)
            let root = result.root
            let mb: Int64 = 1_048_576

            // 하드링크 1회 집계
            let hl = [find(root, "hl1.bin"), find(root, "hl2.bin")].compactMap { $0 }
            #expect(hl.count == 2)
            #expect(hl.reduce(Int64(0)) { $0 + $1.allocatedSize } >= mb)
            #expect(hl.reduce(Int64(0)) { $0 + $1.allocatedSize } < 2 * mb)
            #expect(hl.contains { $0.allocatedSize == 0 })

            // clone은 각자 집계
            #expect(find(root, "orig.bin")!.allocatedSize >= mb)
            #expect(find(root, "clone.bin")!.allocatedSize >= mb)

            // sparse는 할당 크기
            let sp = find(root, "sparse.bin")!
            #expect(sp.logicalSize == 1 << 30)
            #expect(sp.allocatedSize < 64 * mb)

            // 링크 미추적: loop/selflink는 파일(비디렉터리) 노드, 하위 없음
            let loop = find(root, "loop")!
            #expect(!loop.isDirectory && loop.children.isEmpty)
            #expect(!find(root, "selflink")!.isDirectory)
            // 루트 합계: 1MB*(plain + hl 1회 + orig + clone) = 4MB 부근, 1GB 아님
            #expect(root.allocatedSize >= 4 * mb)
            #expect(root.allocatedSize < 64 * mb)

            // 권한 없는 폴더
            if getuid() != 0 {
                #expect(result.skipped.contains { $0.hasSuffix("/locked") })
                #expect(find(root, "hidden.bin") == nil)
            }
        }
    }

    @Test func topFilesLimit() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sl-top-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        for i in 0..<250 {
            try Data(repeating: 1, count: 4096 * (1 + i % 5)).write(to: base.appendingPathComponent("f\(i)"))
        }
        let r = try await Scanner(concurrency: 2).scan(root: base)
        #expect(r.root.children.count == 200)
        #expect(r.root.omittedFileCount == 50)
        let kept = r.root.children.reduce(Int64(0)) { $0 + $1.allocatedSize }
        #expect(r.root.allocatedSize == kept + r.root.omittedBytes)
    }

    @Test func cancellation() async throws {
        let h = Scanner().start(root: URL(fileURLWithPath: "/usr"))
        h.result.cancel()
        do { _ = try await h.result.value } catch is CancellationError { return }
        // 빠르게 끝났다면 정상 완료도 허용
    }

    @Test func testPerfScan() async throws {
        guard let root = ProcessInfo.processInfo.environment["SL_PERF_ROOT"] else { return }
        let t0 = Date()
        let r = try await Scanner().scan(root: URL(fileURLWithPath: root))
        let dt = Date().timeIntervalSince(t0)
        print("PERF: seconds=\(String(format: "%.2f", dt)) nodes=\(countNodes(r.root)) bytes=\(r.root.allocatedSize) skipped=\(r.skipped.count)")
    }
}

// MARK: - A3: 하드링크 결정성, 전체 유지 디렉터리, 합계 보존
extension ScanTests {
    private static func catalogMatcher(home: String) throws -> CatalogMatcher {
        return CatalogMatcher(catalog: try TestSupport.loadCatalog(), home: home, toolResolver: { _ in nil })
    }
    private static func tempBase() throws -> URL {
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("sl-a3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        return b
    }

    @Test func hardLinkAssignmentIsDeterministic() async throws {
        let base = try Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("z"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("a"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("m"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64 * 1024).write(to: base.appendingPathComponent("z/orig"))
        try fm.linkItem(at: base.appendingPathComponent("z/orig"), to: base.appendingPathComponent("m/link1"))
        try fm.linkItem(at: base.appendingPathComponent("z/orig"), to: base.appendingPathComponent("a/link2"))
        for _ in 0..<5 {
            let r = try await Scanner(concurrency: 4).scan(root: base)
            let a = try #require(find(r.root, "a")), m = try #require(find(r.root, "m")), z = try #require(find(r.root, "z"))
            #expect(a.allocatedSize >= 64 * 1024)
            #expect(m.allocatedSize == 0 && z.allocatedSize == 0)
            #expect(r.root.allocatedSize == a.allocatedSize)
        }
    }

    @Test func fullKeepDirectoryKeepsAllFilesOthersLimitedAndTotalsPreserved() async throws {
        let base = try Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        let real = realPathString(base.path)
        let home = real + "/home"
        let prefs = home + "/Library/Preferences", caches = home + "/Library/Caches/foo"
        try fm.createDirectory(atPath: prefs, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
        for i in 0..<250 {
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: prefs + "/com.x.\(i).plist"))
            try Data(repeating: 1, count: 4096 * (1 + i % 3)).write(to: URL(fileURLWithPath: caches + "/f\(i)"))
        }
        let r = try await Scanner(concurrency: 2, fullKeepDirectories: [prefs]).scan(root: base)
        let p = try #require(find(r.root, "Preferences"))
        #expect(p.children.count == 250 && p.omittedBytes == 0)
        let c = try #require(find(r.root, "foo"))
        #expect(c.children.count == 200 && c.omittedFileCount == 50 && c.omittedBytes > 0)
        let kept = c.children.reduce(Int64(0)) { $0 + $1.allocatedSize }
        #expect(c.allocatedSize == kept + c.omittedBytes)
        // 카테고리 합계: 생략분이 foo(user-caches)에 포함되고 전체 합계 보존
        let totals = CategoryTotals.compute(root: r.root, logicalRootPath: r.rootPath,
                                            matcher: try Self.catalogMatcher(home: home), home: home)
        #expect(totals.values.reduce(0, +) == r.root.allocatedSize)
        #expect((totals["user-caches"] ?? 0) == c.allocatedSize)
    }

    @Test func preferencesWithManyPlistsGroupTotalsExact() async throws {
        let base = try Self.tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = realPathString(base.path)
        let home = real + "/home"
        let prefs = home + "/Library/Preferences"
        try FileManager.default.createDirectory(atPath: prefs, withIntermediateDirectories: true)
        for i in 0..<250 {
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: prefs + "/com.foo.Alpha.n\(i).plist"))
        }
        let scanned = try await Scanner(concurrency: 2, fullKeepDirectories: [prefs]).scan(root: base)
        let limited = try await Scanner(concurrency: 2, fullKeepDirectories: []).scan(root: base)

        let apps = [InstalledApp(bundleID: "com.foo.Alpha", displayName: "Alpha")]
        func outcome(_ r: ScanResult) throws -> ScanOutcome {
            let cat = try TestSupport.loadCatalog()
            let index = SystemAppIndex(apps: apps, knownIdentifiers: ["com.foo.Alpha"])
            let inUse = InUseIndex(records: [])
            let attributor = Attributor(home: URL(fileURLWithPath: home), appIndex: index, rules: AttributionRules(), inUse: inUse)
            let matcher = CatalogMatcher(catalog: cat, home: home, toolResolver: { _ in nil })
            return ScanOutcome(result: r, logicalRootPath: r.rootPath, categoryTotals: [:], catalog: cat, volume: nil,
                               trashBytes: nil, previous: nil, topChanges: [], categoryChanges: [], huggingFace: nil,
                               attributor: attributor, matcher: matcher, inUse: inUse, appIndex: index)
        }
        let full = try outcome(scanned).appDataGroups()
        let alpha = try #require(full.first { $0.bundleID == "com.foo.Alpha" })
        #expect(alpha.items.count == 250)
        #expect(alpha.totalBytes == Int64(250) * 4096)
        #expect(alpha.items.allSatisfy { $0.kind == .preferences })
        #expect(!alpha.hasOmittedFiles)

        // 제한 모드: 200개만 항목, 생략분은 합계(알 수 없음 묶음)에 반영되고 플래그 노출
        let lim = try outcome(limited).appDataGroups()
        let la = try #require(lim.first { $0.bundleID == "com.foo.Alpha" })
        #expect(la.items.count == 200)
        let unk = try #require(lim.first { $0.id == AppDataIndex.unknownKey })
        #expect(unk.hasOmittedFiles && unk.omittedBytes == Int64(50) * 4096 && unk.totalBytes == unk.omittedBytes)
        #expect(lim.reduce(Int64(0)) { $0 + $1.totalBytes } == Int64(250) * 4096)
    }
}
