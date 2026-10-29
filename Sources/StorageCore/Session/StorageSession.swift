import Foundation

/// UI용 파사드: 스캔 -> 색인 -> 귀속/카탈로그 -> 카테고리 합계 -> 이력 -> 볼륨/휴지통/HF (PLAN §3, §4~§9).
/// 리소스(JSON) 로드 결과 (PLAN §17 safety-2 / cq-2). 파일 없음과 파싱 오류, 일부 항목 실패를 구분한다.
public enum ResourceLoadStatus: Sendable, Equatable {
    case ok
    case missing(path: String)
    case invalid(reason: String)
    /// 일부 항목만 디코딩 실패해 건너뜀.
    case partial(skipped: Int)

    public var isOK: Bool { self == .ok }
    /// 사용자에게 보일 한국어 사유. 정상이면 nil.
    public var message: String? {
        switch self {
        case .ok: return nil
        case .missing(let p): return "파일을 찾을 수 없습니다: \(p)"
        case .invalid(let r): return "내용이 올바르지 않습니다: \(r)"
        case .partial(let n): return "\(n)개 항목을 읽지 못해 건너뛰었습니다."
        }
    }
}

/// catalog.json / attribution-rules.json 로드 결과 묶음.
public struct ResourceLoadResult: Sendable {
    public var rules: AttributionRules
    public var catalog: Catalog
    public var rulesStatus: ResourceLoadStatus
    public var catalogStatus: ResourceLoadStatus
}

public final class StorageSession: Sendable {
    public static let defaultRoot = "/System/Volumes/Data"
    /// 번들에 리소스가 없을 때 쓰는 개발용 리소스 폴더 환경변수.
    public static let resourcesDirEnvVar = "SL_RESOURCES_DIR"

    let home: URL
    private let rules: AttributionRules
    let catalog: Catalog
    private let historyDirectory: URL
    private let historyStore: HistoryStore
    /// attribution-rules.json 로드 상태.
    public let rulesLoadStatus: ResourceLoadStatus
    /// catalog.json 로드 상태.
    public let catalogLoadStatus: ResourceLoadStatus

    /// - Parameters:
    ///   - resourcesDirectory: 지정하면 번들보다 먼저 이 폴더에서 리소스를 찾는다(테스트·개발용).
    ///   - environment: `SL_RESOURCES_DIR` 조회용 (테스트 주입).
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                bundle: Bundle = .main,
                historyDirectory: URL? = nil,
                resourcesDirectory: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        let r = Self.loadResourcesDetailed(bundle: bundle, resourcesDirectory: resourcesDirectory,
                                           environment: environment)
        self.rules = r.rules; self.catalog = r.catalog
        self.rulesLoadStatus = r.rulesStatus; self.catalogLoadStatus = r.catalogStatus
        let hd = historyDirectory ?? home.appendingPathComponent("Library/Application Support/StorageLens/history")
        self.historyDirectory = hd
        self.historyStore = HistoryStore(directory: hd)
    }

    /// 테스트용: 리소스를 직접 주입.
    init(home: URL, rules: AttributionRules, catalog: Catalog, historyDirectory: URL) {
        self.home = home; self.rules = rules; self.catalog = catalog; self.historyDirectory = historyDirectory
        self.historyStore = HistoryStore(directory: historyDirectory)
        self.rulesLoadStatus = .ok; self.catalogLoadStatus = .ok
    }

    /// 번들의 attribution-rules.json / catalog.json. 없거나 깨지면 빈 값. (폴백 없음; 상세·폴백은 `loadResourcesDetailed`)
    public static func loadResources(bundle: Bundle) -> (AttributionRules, Catalog) {
        var rules = AttributionRules()
        if let u = bundle.url(forResource: "attribution-rules", withExtension: "json"),
           let r = try? AttributionRules(contentsOf: u) { rules = r }
        var catalog = Catalog(entries: [])
        if let u = bundle.url(forResource: "catalog", withExtension: "json"),
           let d = try? Data(contentsOf: u), let c = try? Catalog.load(from: d) { catalog = c }
        return (rules, catalog)
    }

    /// 리소스 위치 순서: 명시 폴더 -> 번들 -> `SL_RESOURCES_DIR` -> 패키지 `Resources/`(개발 실행용).
    /// 항목 단위로 디코딩 실패를 격리하고 사유를 `ResourceLoadStatus`로 돌려준다.
    public static func loadResourcesDetailed(bundle: Bundle,
                                             resourcesDirectory: URL? = nil,
                                             environment: [String: String] = ProcessInfo.processInfo.environment,
                                             packageRoot: URL = StorageSession.packageRoot()) -> ResourceLoadResult {
        var dirs: [URL] = []
        if let d = resourcesDirectory { dirs.append(d) }
        if let env = environment[resourcesDirEnvVar], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        dirs.append(packageRoot.appendingPathComponent("Resources", isDirectory: true))

        func locate(_ name: String) -> (url: URL?, expected: String) {
            if let d = resourcesDirectory {
                let u = d.appendingPathComponent(name + ".json")
                if FileManager.default.fileExists(atPath: u.path) { return (u, u.path) }
            }
            if let u = bundle.url(forResource: name, withExtension: "json") { return (u, u.path) }
            for d in dirs {
                let u = d.appendingPathComponent(name + ".json")
                if FileManager.default.fileExists(atPath: u.path) { return (u, u.path) }
            }
            let first = (dirs.first ?? packageRoot).appendingPathComponent(name + ".json").path
            return (nil, first)
        }

        var rules = AttributionRules(), rulesStatus = ResourceLoadStatus.ok
        let ru = locate("attribution-rules")
        if let u = ru.url {
            do { (rules, rulesStatus) = try lenientRules(Data(contentsOf: u)) }
            catch { rulesStatus = .invalid(reason: describe(error)) }
        } else { rulesStatus = .missing(path: ru.expected) }

        var catalog = Catalog(entries: []), catalogStatus = ResourceLoadStatus.ok
        let cu = locate("catalog")
        if let u = cu.url {
            do { (catalog, catalogStatus) = try lenientCatalog(Data(contentsOf: u)) }
            catch { catalogStatus = .invalid(reason: describe(error)) }
        } else { catalogStatus = .missing(path: cu.expected) }

        return ResourceLoadResult(rules: rules, catalog: catalog, rulesStatus: rulesStatus, catalogStatus: catalogStatus)
    }

    /// 이 소스 파일 기준 패키지 루트 (Sources/StorageCore/Session/StorageSession.swift 에서 4단계 위).
    public static func packageRoot(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func describe(_ error: Error) -> String {
        if let d = error as? DecodingError {
            switch d {
            case .dataCorrupted(let c): return c.debugDescription
            case .keyNotFound(let k, _): return "키 없음: \(k.stringValue)"
            case .typeMismatch(_, let c), .valueNotFound(_, let c): return c.debugDescription
            @unknown default: break
            }
        }
        return error.localizedDescription
    }

    /// 배열 항목 단위 디코딩. 최상위가 배열이 아니면 throw. 전부 실패하면 invalid.
    static func lenientCatalog(_ data: Data) throws -> (Catalog, ResourceLoadStatus) {
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            return (Catalog(entries: []), .invalid(reason: "최상위가 배열이 아닙니다"))
        }
        var entries: [CatalogEntry] = [], skipped = 0
        let dec = JSONDecoder()
        for item in arr {
            if let d = try? JSONSerialization.data(withJSONObject: item),
               let e = try? dec.decode(CatalogEntry.self, from: d) { entries.append(e) } else { skipped += 1 }
        }
        if entries.isEmpty && skipped > 0 { return (Catalog(entries: []), .invalid(reason: "모든 항목(\(skipped)개)을 읽지 못했습니다")) }
        return (Catalog(entries: entries), skipped > 0 ? .partial(skipped: skipped) : .ok)
    }

    /// pathRules는 항목 단위, vendorNames/appleDaemons는 키 단위로 격리.
    static func lenientRules(_ data: Data) throws -> (AttributionRules, ResourceLoadStatus) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (AttributionRules(), .invalid(reason: "최상위가 객체가 아닙니다"))
        }
        let dec = JSONDecoder()
        var skipped = 0
        var pathRules: [AttributionRules.PathRule] = []
        for item in (obj["pathRules"] as? [Any]) ?? [] {
            if let d = try? JSONSerialization.data(withJSONObject: item),
               let r = try? dec.decode(AttributionRules.PathRule.self, from: d) { pathRules.append(r) } else { skipped += 1 }
        }
        func strings(_ key: String) -> [String: String] {
            var out: [String: String] = [:]
            for (k, v) in (obj[key] as? [String: Any]) ?? [:] {
                if let s = v as? String { out[k] = s } else { skipped += 1 }
            }
            return out
        }
        let rules = AttributionRules(pathRules: pathRules, vendorNames: strings("vendorNames"),
                                     appleDaemons: strings("appleDaemons"))
        if rules.pathRules.isEmpty && rules.vendorNames.isEmpty && rules.appleDaemons.isEmpty && skipped > 0 {
            return (rules, .invalid(reason: "모든 항목(\(skipped)개)을 읽지 못했습니다"))
        }
        return (rules, skipped > 0 ? .partial(skipped: skipped) : .ok)
    }

    public var hasRules: Bool { !rules.pathRules.isEmpty }
    public var hasCatalog: Bool { !catalog.entries.isEmpty }
    /// 이 세션이 로드·격리한 손상 이력 파일 수 (corrupt/ 로 옮김). 스캔·이력 로드 후 읽는다.
    public var historyCorruptCount: Int { historyStore.corruptFileCount }
    /// 미래 schemaVersion 이라 건너뛴 이력 파일 수.
    public var historyFutureVersionSkippedCount: Int { historyStore.skippedFutureVersionCount }

    /// 스캔 + 후처리. 취소 시 CancellationError (후처리 중 취소 포함: 결과를 반환하지 않고 이력도 저장하지 않는다).
    /// - Parameter runningBundleIDs: 호출자가 MainActor에서 수집한 실행 중 앱 번들 ID.
    public func scan(root: String = StorageSession.defaultRoot,
                     runningBundleIDs: Set<String>,
                     onProgress: @escaping @Sendable (ScanProgress) -> Void,
                     onFinishing: @escaping @Sendable () -> Void = {}) async throws -> ScanOutcome {
        let handle = Scanner().start(root: URL(fileURLWithPath: root, isDirectory: true))
        let pump = Task.detached { for await p in handle.progress { onProgress(p) } }
        defer { pump.cancel() }
        let result: ScanResult = try await withTaskCancellationHandler {
            try await handle.result.value
        } onCancel: { handle.result.cancel() }
        try Task.checkCancellation()
        pump.cancel()
        onFinishing()
        let home = self.home, rules = self.rules, catalog = self.catalog, store = historyStore
        let post = Task.detached {
            try await Self.postProcess(result: result, home: home, rules: rules, catalog: catalog,
                                       runningBundleIDs: runningBundleIDs, historyStore: store)
        }
        let outcome = try await withTaskCancellationHandler { try await post.value } onCancel: { post.cancel() }
        try Task.checkCancellation()
        return outcome
    }

    static func postProcess(result: ScanResult, home: URL, rules: AttributionRules, catalog: Catalog,
                            runningBundleIDs: Set<String>, historyDirectory: URL) async throws -> ScanOutcome {
        try await postProcess(result: result, home: home, rules: rules, catalog: catalog,
                              runningBundleIDs: runningBundleIDs, historyStore: HistoryStore(directory: historyDirectory))
    }

    static func postProcess(result: ScanResult, home: URL, rules: AttributionRules, catalog: Catalog,
                            runningBundleIDs: Set<String>, historyStore store: HistoryStore) async throws -> ScanOutcome {
        let homePath = home.standardizedFileURL.path
        let logicalRoot = ScanOutcome.logicalPath(result.rootPath)

        try Task.checkCancellation()
        let base = SystemAppIndex.build(home: home, vendorNames: rules.vendorNames)
        let index = SystemAppIndex(apps: base.apps,
                                   knownIdentifiers: base.knownIdentifiers.union(runningBundleIDs),
                                   runningBundleIDs: base.runningBundleIDs.union(runningBundleIDs))
        try Task.checkCancellation()
        let inUse = InUseIndex.snapshot()
        let locator = ToolLocator(home: home)
        let attributor = Attributor(home: home, appIndex: index, rules: rules, inUse: inUse, toolLocator: locator)
        let matcher = CatalogMatcher(catalog: catalog, home: homePath,
                                     toolResolver: { locator.locate($0).map { URL(fileURLWithPath: $0) } })

        try Task.checkCancellation()
        let totals = CategoryTotals.compute(root: result.root, logicalRootPath: logicalRoot, matcher: matcher,
                                            home: homePath,
                                            attribute: { attributor.attribute(URL(fileURLWithPath: $0)) })
        try Task.checkCancellation()

        // 이력 비교 (저장은 모든 단계 후, 취소되지 않았을 때만)
        let summary = ScanSummary.make(from: result, categoryTotals: totals, scannedAt: result.finishedAt)
        let previous = store.latest(rootPath: result.rootPath, before: result.finishedAt)
        var topChanges: [SummaryChange] = [], catChanges: [SummaryChange] = []
        if let previous {
            topChanges = HistoryDiff.topChanges(previous: previous, current: summary, limit: 10).map {
                SummaryChange(path: ScanOutcome.logicalPath($0.path), previous: $0.previous, current: $0.current)
            }
            catChanges = HistoryDiff.categoryChanges(previous: previous, current: summary)
        }

        // 휴지통
        try Task.checkCancellation()
        let trashPath = homePath + "/.Trash"
        let skipped = Set(result.skipped.map(ScanOutcome.logicalPath))
        var trash: Int64?
        if skipped.contains(trashPath) {
            trash = nil
        } else if let n = ScanOutcome.find(root: result.root, rootPath: logicalRoot, path: trashPath) {
            trash = n.allocatedSize
        } else if let r = try? await Scanner().scan(root: URL(fileURLWithPath: trashPath)) {
            trash = r.skipped.isEmpty ? r.root.allocatedSize : nil
        }

        // Hugging Face (스캔 범위가 홈을 포함할 때만 의미 있음)
        try Task.checkCancellation()
        var hf: HuggingFaceOverview?
        let hfRoot = URL(fileURLWithPath: homePath + "/.cache/huggingface")
        if ScanOutcome.find(root: result.root, rootPath: logicalRoot, path: hfRoot.path) != nil {
            let listing = HuggingFaceInventory.list(cacheRoot: hfRoot)
            let blobs = ScanOutcome.find(root: result.root, rootPath: logicalRoot, path: listing.blobsPath.path)
            hf = HuggingFaceOverview(items: listing.items, blobsBytes: blobs?.allocatedSize,
                                     blobsExists: listing.blobsExists, note: Catalog.huggingFaceNote)
        }

        // 마지막 취소 확인 후에만 이력 저장
        try Task.checkCancellation()
        var saveError: String?
        do { try store.save(summary) } catch { saveError = "스캔 이력을 저장하지 못했습니다: \(error.localizedDescription)" }

        return ScanOutcome(result: result, logicalRootPath: logicalRoot, categoryTotals: totals, catalog: catalog,
                           volume: VolumeInfo.read(), trashBytes: trash, previous: previous,
                           topChanges: topChanges, categoryChanges: catChanges, huggingFace: hf,
                           attributor: attributor, matcher: matcher, inUse: inUse, appIndex: index,
                           historySaveError: saveError)
    }

    /// 다운로드 출처 지연 조회 (상세 패널). 호출자는 백그라운드에서 부른다.
    public static func downloadOrigin(path: String) -> DownloadOrigin? {
        DownloadOrigin.lookup(URL(fileURLWithPath: path))
    }
}
