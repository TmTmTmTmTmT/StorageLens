import XCTest
import AppKit
@testable import StorageCore

/// 검증용 E2E (SL_E2E=1 일 때만). 실제 홈/기본 historyDirectory에 이력을 쓴다. Cleaner 실행은 하지 않는다.
final class SessionE2ETests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var historyDir: URL { home.appendingPathComponent("Library/Application Support/StorageLens/history") }
    private var root: URL { home.appendingPathComponent("Library/Caches/com.kimmingyu.StorageLens.test") }
    private var resourcesDir: URL {
        TestSupport.resourcesDirectory
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SL_E2E"] == "1", "SL_E2E=1 일 때만 실행")
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1_000_000).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 8, count: 2_000_000).write(to: sub.appendingPathComponent("b.bin"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func jsonFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: historyDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
    }

    private func runScan(_ session: StorageSession, label: String) async throws -> ScanOutcome {
        // 앱(AppModel.startScan)과 같은 호출: 실행 중 번들 ID 수집 -> session.scan(root:runningBundleIDs:onProgress:onFinishing:)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let before = Set(jsonFiles())
        let out = try await session.scan(root: root.path, runningBundleIDs: running,
                                         onProgress: { _ in }, onFinishing: {})
        let after = Set(jsonFiles())
        print("[E2E:\(label)] hasRules=\(session.hasRules) hasCatalog=\(session.hasCatalog)")
        print("[E2E:\(label)] historyDir exists=\(FileManager.default.fileExists(atPath: historyDir.path)) json before=\(before.count) after=\(after.count) new=\(after.subtracting(before).sorted())")
        print("[E2E:\(label)] logicalRoot=\(out.logicalRootPath) rootPath=\(out.result.rootPath) rootSize=\(out.root.allocatedSize) skipped=\(out.skippedCount)")
        print("[E2E:\(label)] categoryTotals=\(out.categoryTotals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })")
        for p in [out.logicalRootPath, out.logicalRootPath + "/sub", out.logicalRootPath + "/a.bin"] {
            let a = out.attribution(forPath: p)
            print("[E2E:\(label)] attribution \(p) -> appName=\(a.appName) bundleID=\(a.bundleID ?? "nil") conf=\(a.confidence) orphan=\(a.isOrphanSuspect) rule=\(a.rule)")
        }
        // plan만 (실행 금지)
        let cleaner = session.makeCleaner(outcome: out, inUse: InUseIndex.snapshot())
        let plan = cleaner.plan([CleanupSelection(path: root.path)])
        print("[E2E:\(label)] plan items=\(plan.items.map { "\($0.path) size=\($0.sizeBytes) method=\($0.method) entry=\($0.entryID ?? "nil") warn=\($0.warnings)" })")
        print("[E2E:\(label)] plan rejected=\(plan.rejected)")
        return out
    }

    /// 앱 경로 그대로: StorageSession() 기본 init (Bundle.main = 테스트 번들이라 리소스 없음 가능).
    func testAppPathDefaultInit() async throws {
        let session = StorageSession()
        let out = try await runScan(session, label: "default-init")
        XCTAssertGreaterThan(out.root.allocatedSize, 0)
        XCTAssertFalse(jsonFiles().isEmpty, "history json 이 생성되지 않음: \(historyDir.path)")
    }

    /// 리소스 주입: Resources/*.json 을 #filePath 기준으로 로드. 홈/historyDirectory 는 앱 기본값과 동일.
    func testInjectedResources() async throws {
        let rules = try AttributionRules(contentsOf: resourcesDir.appendingPathComponent("attribution-rules.json"))
        let catalog = try Catalog.load(from: Data(contentsOf: resourcesDir.appendingPathComponent("catalog.json")))
        let session = StorageSession(home: home, rules: rules, catalog: catalog, historyDirectory: historyDir)
        let out = try await runScan(session, label: "injected")
        XCTAssertGreaterThan(out.root.allocatedSize, 0)
        XCTAssertFalse(jsonFiles().isEmpty)
    }
}
