import Testing
import Foundation
@testable import StorageCore

@Suite struct AppDataTests {
    static let home = "/Users/t"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func dir(_ name: String, _ children: [Node] = []) -> Node {
        Node(name: name, isDirectory: true, allocatedSize: children.reduce(0) { $0 + $1.allocatedSize },
             logicalSize: 0, inode: 1, devID: 1, modified: now, children: children)
    }
    static func file(_ name: String, _ size: Int64, dataless: Bool = false) -> Node {
        Node(name: name, isDirectory: false, allocatedSize: dataless ? 0 : size, logicalSize: size,
             inode: 2, devID: 1, modified: now, isDataless: dataless)
    }

    static let apps = [
        InstalledApp(bundleID: "com.foo.Alpha", displayName: "Alpha"),
        InstalledApp(bundleID: "com.bar.Beta", displayName: "Beta"),
        InstalledApp(bundleID: "com.apple.Pages", displayName: "Pages"),
    ]

    static func outcome(tree: Node, records: [OpenFileRecord] = []) throws -> ScanOutcome {
        let cat = try TestSupport.loadCatalog()
        let index = SystemAppIndex(apps: apps, knownIdentifiers: Set(apps.map(\.bundleID)))
        let inUse = InUseIndex(records: records)
        let rules = AttributionRules()
        let attributor = Attributor(home: URL(fileURLWithPath: home), appIndex: index, rules: rules, inUse: inUse)
        let matcher = CatalogMatcher(catalog: cat, home: home, toolResolver: { _ in nil })
        let result = ScanResult(rootPath: "/", root: tree, skipped: [], startedAt: now, finishedAt: now)
        return ScanOutcome(result: result, logicalRootPath: "/", categoryTotals: [:], catalog: cat, volume: nil,
                           trashBytes: nil, previous: nil, topChanges: [], categoryChanges: [], huggingFace: nil,
                           attributor: attributor, matcher: matcher, inUse: inUse, appIndex: index)
    }

    static func tree() -> Node {
        dir("/", [dir("Users", [dir("t", [
            dir("Library", [
                dir("Caches", [dir("com.foo.Alpha", [file("a", 100)]), dir("com.apple.x", [file("c", 500)])]),
                dir("Application Support", [dir("Alpha", [file("d", 300)]), dir("Beta", [file("e", 50)])]),
                dir("Containers", [dir("com.apple.Safari", [file("s", 40)])]),
                dir("Logs", [dir("Alpha", [file("l", 10)])]),
                dir("Mobile Documents", [
                    dir("com~apple~CloudDocs", [dir("Docs", [file("x", 1000), file("y", 0, dataless: true)]),
                                                file("z", 0, dataless: true)]),
                    dir("iCloud~com~foo~Alpha", [file("n", 200)]),
                    dir("iCloud~org~zed~Unknown", [file("q", 30)]),
                ]),
            ]),
            dir(".cache", [dir("Beta", [file("k", 5)])]),
        ])])])
    }

    @Test func groupsByBundleIDAndSortsBySize() throws {
        let groups = try Self.outcome(tree: Self.tree()).appDataGroups()
        let names = groups.map(\.appName)
        #expect(names.last == "macOS 시스템")
        #expect(groups.last?.isSystem == true)
        #expect(groups.last?.totalBytes == 540)             // com.apple.x 500 + Safari 40
        let nonSystem = groups.filter { !$0.isSystem }
        #expect(nonSystem.map(\.totalBytes) == nonSystem.map(\.totalBytes).sorted(by: >))
        let alpha = try #require(nonSystem.first { $0.bundleID == "com.foo.Alpha" })
        #expect(alpha.id == "com.foo.Alpha")
        #expect(alpha.totalBytes == 410)
        #expect(Set(alpha.items.map(\.locationKind)) == ["캐시", "앱 데이터", "로그"])
        #expect(alpha.items.map(\.size) == [300, 100, 10])
        let beta = try #require(nonSystem.first { $0.bundleID == "com.bar.Beta" })
        #expect(beta.items.map(\.locationKind) == ["앱 데이터"])
        // ~/.cache 직속은 경로 규칙이 없으면 귀속 불명 -> 폴더 이름별 묶음 ("알 수 없음" 한 덩어리 아님)
        #expect(groups.first { $0.id == AppDataIndex.unknownKey } == nil)
        #expect(nonSystem.first == alpha)
    }

    @Test func unknownDotCacheChildGetsOwnGroup() throws {
        let g = try #require(try Self.outcome(tree: Self.tree()).appDataGroups().first { $0.id == "cache:Beta" })
        #expect(g.appName == "Beta")
        #expect(g.items.map(\.locationKind) == ["개발 도구 캐시"])
        #expect(g.totalBytes == 5 && !g.isSystem)
    }

    @Test func systemGroupHasContainerKind() throws {
        let sys = try #require(try Self.outcome(tree: Self.tree()).appDataGroups().first { $0.isSystem })
        #expect(sys.bundleID == nil)
        #expect(sys.items.contains { $0.locationKind == "컨테이너" })
    }

    @Test func runningFlagFromInjectedIDsAndInUse() throws {
        let o = try Self.outcome(tree: Self.tree(),
                                 records: [OpenFileRecord(pid: 1, processName: "Beta", path: "/Users/t/Library/Application Support/Beta/e")])
        let plain = o.appDataGroups()
        #expect(plain.first { $0.bundleID == "com.foo.Alpha" }?.isRunning == false)
        #expect(plain.first { $0.bundleID == "com.bar.Beta" }?.isRunning == true)   // InUse
        let running = o.appDataGroups(runningBundleIDs: ["COM.foo.alpha"])
        #expect(running.first { $0.bundleID == "com.foo.Alpha" }?.isRunning == true)
        // 캐시된 기본 결과는 오염되지 않음
        #expect(o.appDataGroups().first { $0.bundleID == "com.foo.Alpha" }?.isRunning == false)
    }

    @Test func iCloudNamesAndCounts() throws {
        let inv = try Self.outcome(tree: Self.tree()).iCloudInventory()
        func c(_ f: String) -> ICloudContainer? { inv.containers.first { $0.folderName == f } }
        #expect(c("com~apple~CloudDocs")?.displayName == "iCloud Drive")
        #expect(c("iCloud~com~foo~Alpha")?.displayName == "Alpha")
        #expect(c("iCloud~org~zed~Unknown")?.displayName == "Unknown")
        let drive = try #require(c("com~apple~CloudDocs"))
        #expect(drive.localBytes == 1000)
        #expect(drive.cloudOnlyFileCount == 2)
        #expect(drive.fileCount == 3)
        #expect(inv.totalLocalBytes == 1230)
        #expect(inv.totalCloudOnly == 2)
        #expect(inv.containers.first?.folderName == "com~apple~CloudDocs")
    }

    @Test func iCloudSubfolders() throws {
        let o = try Self.outcome(tree: Self.tree())
        let inv = o.iCloudInventory()
        let drive = try #require(inv.containers.first { $0.folderName == "com~apple~CloudDocs" })
        let subs = inv.subfolders(ofContainer: drive.path, in: o)
        #expect(subs.map(\.name) == ["Docs"])
        #expect(subs.first?.localBytes == 1000)
    }

    @Test func pendingUploadsOnPlainFiles() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sl-icloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        for i in 0..<5 { try Data("x".utf8).write(to: d.appendingPathComponent("sub/f\(i)")) }
        let r = await ICloudInventory.pendingUploads(containerPath: d.path)
        #expect(r.pending == 0 && r.checked == 5 && !r.truncated)
        let t = await ICloudInventory.pendingUploads(containerPath: d.path, limit: 3)
        #expect(t.checked == 3 && t.truncated)
    }
}

// MARK: - A3: 위치 enum, 제조사 공용 묶음
extension AppDataTests {
    @Test func locationKindEnumMapping() {
        let map = Dictionary(uniqueKeysWithValues: AppDataIndex.locations.map { ($0.rel, $0.kind) })
        #expect(map["Library/Caches"] == .caches)
        #expect(map["Library/Preferences"] == .preferences)
        #expect(map["Library/Application Support"] == .applicationSupport)
        #expect(map[".cache"] == .devCache)
        #expect(AppDataLocationKind.caches.label == "캐시" && AppDataLocationKind.preferences.label == "설정")
        #expect(AppDataLocationKind.devCache.label == "개발 도구 캐시")
        #expect(AppDataLocationKind.caches.isCache && AppDataLocationKind.devCache.isCache && !AppDataLocationKind.logs.isCache)
        #expect(Set(AppDataIndex.locations.map(\.kind)).count == AppDataIndex.locations.count)
    }

    @Test func vendorSharedGroupKeyAndRunning() throws {
        let tree = Self.dir("/", [Self.dir("Users", [Self.dir("t", [Self.dir("Library", [
            Self.dir("Caches", [Self.dir("Google", [Self.file("g", 70)])]),
        ])])])])
        let apps = [InstalledApp(bundleID: "com.google.Chrome", displayName: "Chrome", vendorName: "Google"),
                    InstalledApp(bundleID: "com.google.Drive", displayName: "Drive", vendorName: "Google")]
        let cat = try TestSupport.loadCatalog()
        let index = SystemAppIndex(apps: apps)
        let inUse = InUseIndex(records: [])
        let attributor = Attributor(home: URL(fileURLWithPath: Self.home), appIndex: index, rules: AttributionRules(), inUse: inUse)
        let matcher = CatalogMatcher(catalog: cat, home: Self.home, toolResolver: { _ in nil })
        let result = ScanResult(rootPath: "/", root: tree, skipped: [], startedAt: Self.now, finishedAt: Self.now)
        let o = ScanOutcome(result: result, logicalRootPath: "/", categoryTotals: [:], catalog: cat, volume: nil,
                            trashBytes: nil, previous: nil, topChanges: [], categoryChanges: [], huggingFace: nil,
                            attributor: attributor, matcher: matcher, inUse: inUse, appIndex: index)
        let g = try #require(o.appDataGroups().first { $0.id == "vendor:google" })
        #expect(g.appName == "Google 공용" && g.isVendorShared && g.bundleID == nil && g.totalBytes == 70)
        #expect(g.isRunning == false)
        #expect(o.appDataGroups(runningBundleIDs: ["com.google.Drive"]).first { $0.id == "vendor:google" }?.isRunning == true)
    }
}
