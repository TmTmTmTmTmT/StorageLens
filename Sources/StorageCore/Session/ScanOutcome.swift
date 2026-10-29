import Foundation

public enum RowSort: Sendable { case size, modified }

/// 목록 한 행 (귀속·사용 중 포함).
public struct NodeRow: Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var isDataless: Bool
    public var attribution: Attribution
    public var inUseBy: [String]
    /// 상위 200개 제한으로 빠진 작은 파일들의 요약 행
    public var isOmittedSummary: Bool
}

public struct NodeDetail: Sendable, Equatable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var isDataless: Bool
    public var attribution: Attribution
    public var catalog: CatalogMatch?
    public var inUseBy: [String]
}

public struct HuggingFaceOverview: Sendable, Equatable {
    public var items: [HuggingFaceInventory.Item]
    public var blobsBytes: Int64?
    public var blobsExists: Bool
    public var note: String
}

/// 스캔 완료 후의 모든 결과. 귀속·카탈로그 일치는 질의 시점에 지연 계산한다 (Attributor 메모이즈).
public final class ScanOutcome: Sendable {
    public let result: ScanResult
    /// 트리 루트의 논리 경로 (`/System/Volumes/Data` 접두 제거).
    public let logicalRootPath: String
    public let categoryTotals: [String: Int64]
    public let catalog: Catalog
    public let volume: VolumeInfo?
    /// 휴지통 크기. 읽을 수 없으면 nil.
    public let trashBytes: Int64?
    public let previous: ScanSummary?
    public let topChanges: [SummaryChange]
    public let categoryChanges: [SummaryChange]
    public let huggingFace: HuggingFaceOverview?
    public let skippedCount: Int
    /// 스캔 이력 저장 실패 시 사용자 표시용 사유 (PLAN §16.6). 성공이면 nil.
    public let historySaveError: String?

    let attributor: Attributor
    let matcher: CatalogMatcher
    let inUse: InUseIndex
    /// 설치 앱 색인 (iCloud 컨테이너 표시 이름 조회용). 주입하지 않으면 nil.
    let appIndex: (any AppIndex)?
    let derivedCache = OutcomeDerivedCache()

    init(result: ScanResult, logicalRootPath: String, categoryTotals: [String: Int64], catalog: Catalog,
         volume: VolumeInfo?, trashBytes: Int64?, previous: ScanSummary?, topChanges: [SummaryChange],
         categoryChanges: [SummaryChange], huggingFace: HuggingFaceOverview?,
         attributor: Attributor, matcher: CatalogMatcher, inUse: InUseIndex,
         appIndex: (any AppIndex)? = nil, historySaveError: String? = nil) {
        self.appIndex = appIndex
        self.historySaveError = historySaveError
        self.result = result; self.logicalRootPath = logicalRootPath; self.categoryTotals = categoryTotals
        self.catalog = catalog; self.volume = volume; self.trashBytes = trashBytes; self.previous = previous
        self.topChanges = topChanges; self.categoryChanges = categoryChanges; self.huggingFace = huggingFace
        self.skippedCount = result.skipped.count
        self.attributor = attributor; self.matcher = matcher; self.inUse = inUse
    }

    public var root: Node { result.root }

    // MARK: - 트리 조회

    /// 자식이 이 수를 넘는 디렉터리는 이름 -> 인덱스 맵(LRU 캐시)으로 조회한다 (선형 탐색 회피).
    static let childMapThreshold = 256

    public func node(at path: String) -> Node? {
        if path == logicalRootPath { return root }
        let prefix = logicalRootPath == "/" ? "/" : logicalRootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        var cur = logicalRootPath
        for comp in path.dropFirst(prefix.count).split(separator: "/") {
            let name = String(comp)
            if node.children.count > Self.childMapThreshold {
                let map = derivedCache.childMap(for: cur) {
                    var m: [String: Int] = [:]
                    m.reserveCapacity(node.children.count)
                    for (i, c) in node.children.enumerated() where m[c.name] == nil { m[c.name] = i }
                    return m
                }
                guard let i = map[name] else { return nil }
                node = node.children[i]
            } else {
                guard let next = node.children.first(where: { $0.name == name }) else { return nil }
                node = next
            }
            cur = cur == "/" ? "/" + name : cur + "/" + name
        }
        return node
    }

    static func find(root: Node, rootPath: String, path: String) -> Node? {
        if path == rootPath { return root }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        var node = root
        for comp in path.dropFirst(prefix.count).split(separator: "/") {
            guard let next = node.children.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }

    /// 루트 -> path 까지의 (이름, 경로) 목록 (브레드크럼용). 루트 포함.
    public func breadcrumb(for path: String) -> [(name: String, path: String)] {
        var out: [(String, String)] = [(logicalRootPath == "/" ? "/" : (logicalRootPath as NSString).lastPathComponent, logicalRootPath)]
        let prefix = logicalRootPath == "/" ? "/" : logicalRootPath + "/"
        guard path != logicalRootPath, path.hasPrefix(prefix) else { return out }
        var cur = logicalRootPath
        for comp in path.dropFirst(prefix.count).split(separator: "/") {
            cur = cur == "/" ? "/" + comp : cur + "/" + comp
            out.append((String(comp), cur))
        }
        return out
    }

    public func parentPath(of path: String) -> String? {
        guard path != logicalRootPath else { return nil }
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }

    // MARK: - 지연 질의

    public func attribution(forPath path: String) -> Attribution {
        attributor.attribute(URL(fileURLWithPath: path))
    }

    /// 자식이 이 수를 넘는 폴더는 상위 `rowKeepCount` 개 + 요약 행으로 줄인다 (perf-4).
    public static let rowTruncateThreshold = 5_000
    public static let rowKeepCount = 1_000

    /// 탐색 목록 행. (focusPath, 정렬) 결과는 작은 LRU 에 캐시된다 (이 객체 = 스캔 1회이므로 새 스캔 시 자연히 비워짐).
    /// 호출 Task 가 취소되면 중간에 멈추고 빈 배열을 돌려주며 캐시하지 않는다.
    public func rows(focusPath: String, sort: RowSort) -> [NodeRow] {
        rows(focusPath: focusPath, sort: sort, truncateAbove: Self.rowTruncateThreshold, keep: Self.rowKeepCount)
    }

    func rows(focusPath: String, sort: RowSort, truncateAbove: Int, keep: Int) -> [NodeRow] {
        let key = RowsKey(path: focusPath, sort: sort)
        let cacheable = truncateAbove == Self.rowTruncateThreshold && keep == Self.rowKeepCount
        if cacheable, let hit = derivedCache.cachedRows(key) { return hit }
        guard let focus = node(at: focusPath) else { return [] }
        let kids = focus.children
        var order = Array(kids.indices)
        switch sort {
        case .size:
            order.sort { kids[$0].allocatedSize != kids[$1].allocatedSize ? kids[$0].allocatedSize > kids[$1].allocatedSize : kids[$0].name < kids[$1].name }
        case .modified:
            order.sort { kids[$0].modified != kids[$1].modified ? kids[$0].modified > kids[$1].modified : kids[$0].name < kids[$1].name }
        }
        let truncated = kids.count > truncateAbove
        let shown = truncated ? Array(order.prefix(keep)) : order
        // 트리 경로는 스캐너가 심볼릭 링크를 따라가지 않고 만든 실경로이므로(루트가 실경로일 때)
        // InUse 질의의 링크 해석을 생략한다. 루트가 링크를 포함하면 기존 방식으로 폴백.
        let fast = rootIsRealPath
        var rows: [NodeRow] = []
        rows.reserveCapacity(shown.count + 1)
        for (n, i) in shown.enumerated() {
            if n & 63 == 0, Task.isCancelled { return [] }
            let c = kids[i]
            let p = focusPath == "/" ? "/" + c.name : focusPath + "/" + c.name
            rows.append(NodeRow(id: p, name: c.name, path: p, isDirectory: c.isDirectory, size: c.allocatedSize,
                                modified: c.modified, isDataless: c.isDataless,
                                attribution: attribution(forPath: p),
                                inUseBy: fast ? inUse.processes(usingRealPath: p) : inUse.processes(usingPathPrefix: p),
                                isOmittedSummary: false))
        }
        var extraCount = focus.omittedFileCount
        var extraBytes = focus.omittedBytes
        if truncated {
            for i in order.dropFirst(keep) { extraCount += 1; extraBytes += kids[i].allocatedSize }
        }
        if extraCount > 0 {
            let title = truncated ? "나머지 \(extraCount)개" : "작은 파일 \(extraCount)개"
            rows.append(NodeRow(id: focusPath + "#omitted", name: title,
                                path: focusPath, isDirectory: false, size: extraBytes,
                                modified: focus.modified, isDataless: false,
                                attribution: attribution(forPath: focusPath), inUseBy: [], isOmittedSummary: true))
        }
        if Task.isCancelled { return [] }
        if cacheable { derivedCache.storeRows(rows, for: key) }
        return rows
    }

    /// 트리 루트의 논리 경로가 심볼릭 링크를 포함하지 않는지 (1회 계산).
    var rootIsRealPath: Bool {
        derivedCache.rootIsReal {
            InUseIndex.normalize(URL(fileURLWithPath: logicalRootPath).resolvingSymlinksInPath().path)
                == InUseIndex.normalize(logicalRootPath)
        }
    }

    public func detail(forPath path: String) -> NodeDetail? {
        guard let n = node(at: path) else { return nil }
        let attr = attribution(forPath: path)
        let root = self.root, rootPath = logicalRootPath
        let match = matcher.match(path: path, attribution: attr, modified: { p in
            Self.find(root: root, rootPath: rootPath, path: p)?.modified
        })
        return NodeDetail(path: path, name: n.name, isDirectory: n.isDirectory, size: n.allocatedSize,
                          modified: n.modified, isDataless: n.isDataless, attribution: attr, catalog: match,
                          inUseBy: inUse.processes(usingPathPrefix: path))
    }

    public func sunburst(focusPath: String) -> [SunburstArc] {
        guard let n = node(at: focusPath) else { return [] }
        return SunburstLayout.arcs(focus: n, focusPath: focusPath)
    }

    /// `/System/Volumes/Data` 접두를 뗀 논리 경로.
    public static func logicalPath(_ p: String) -> String {
        let prefix = "/System/Volumes/Data"
        if p == prefix { return "/" }
        if p.hasPrefix(prefix + "/") { return String(p.dropFirst(prefix.count)) }
        return p
    }
}

/// 낡은 비동기 결과 폐기용 세대 토큰. 새 작업을 시작할 때 `advance()`, 반영 직전 `isCurrent(_:)` 확인.
public struct GenerationGate: Sendable {
    private var value = 0
    public init() {}
    public mutating func advance() -> Int { value &+= 1; return value }
    public func isCurrent(_ g: Int) -> Bool { g == value }
}

struct RowsKey: Hashable, Sendable {
    let path: String
    let sort: RowSort
}

extension RowSort: Hashable {}

/// 작은 값 타입 LRU (스레드 안전하지 않음 - 호출자가 잠금).
struct LRUCache<Key: Hashable, Value> {
    let capacity: Int
    private var store: [Key: Value] = [:]
    private var order: [Key] = []   // 오래된 것이 앞

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { store.count }
    var keysOldestFirst: [Key] { order }

    mutating func get(_ k: Key) -> Value? {
        guard let v = store[k] else { return nil }
        touch(k)
        return v
    }

    mutating func set(_ k: Key, _ v: Value) {
        store[k] = v
        touch(k)
        while order.count > capacity { store[order.removeFirst()] = nil }
    }

    mutating func removeAll() { store.removeAll(); order.removeAll() }

    private mutating func touch(_ k: Key) {
        if let i = order.firstIndex(of: k) { order.remove(at: i) }
        order.append(k)
    }
}

/// 조회 실패(nil)도 기억하는 상한 있는 캐시 (아이콘 등). 스레드 안전. compute 는 잠금 밖에서 실행된다.
public final class LookupCache<Value>: @unchecked Sendable {
    public enum Entry { case hit(Value), miss }
    private let lock = NSLock()
    private var lru: LRUCache<String, Entry>

    public init(capacity: Int) { lru = LRUCache(capacity: capacity) }

    /// 캐시에 있으면 항목, 없으면 nil (조회한 적 없음).
    public func peek(_ key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return lru.get(key)
    }

    public func store(_ key: String, _ value: Value?) {
        lock.lock(); defer { lock.unlock() }
        lru.set(key, value.map { .hit($0) } ?? .miss)
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return lru.count }

    /// 캐시되어 있으면 compute 를 호출하지 않는다. nil 결과(음성)도 캐시한다.
    public func value(for key: String, compute: () -> Value?) -> Value? {
        if let e = peek(key) { if case .hit(let v) = e { return v } else { return nil } }
        let v = compute()
        store(key, v)
        return v
    }
}

/// 앱별·iCloud 파생 결과 캐시 (스레드 안전).
final class OutcomeDerivedCache: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [AppDataGroup]?
    private var icloud: ICloudInventory?
    private var rootReal: Bool?
    private var rowsLRU = LRUCache<RowsKey, [NodeRow]>(capacity: 16)

    func cachedRows(_ k: RowsKey) -> [NodeRow]? {
        lock.lock(); defer { lock.unlock() }
        return rowsLRU.get(k)
    }

    func storeRows(_ r: [NodeRow], for k: RowsKey) {
        lock.lock(); defer { lock.unlock() }
        rowsLRU.set(k, r)
    }

    private var childMaps = LRUCache<String, [String: Int]>(capacity: 32)

    func childMap(for dir: String, _ make: () -> [String: Int]) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        if let m = childMaps.get(dir) { return m }
        let m = make(); childMaps.set(dir, m); return m
    }

    func rootIsReal(_ make: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let rootReal { return rootReal }
        let v = make(); rootReal = v; return v
    }

    func appDataGroups(_ make: () -> [AppDataGroup]) -> [AppDataGroup] {
        lock.lock(); defer { lock.unlock() }
        if let groups { return groups }
        let g = make(); groups = g; return g
    }

    func iCloud(_ make: () -> ICloudInventory) -> ICloudInventory {
        lock.lock(); defer { lock.unlock() }
        if let icloud { return icloud }
        let i = make(); icloud = i; return i
    }
}

// MARK: - 앱별 데이터 · iCloud (PLAN §16.3, §16.4)

public extension ScanOutcome {
    /// 앱별 데이터 묶음 (크기 내림차순, macOS 시스템은 맨 뒤). 기본 계산은 1회 캐시, 실행 중 표시만 호출마다 덧씌운다.
    /// 메인 액터 밖에서 호출 가능.
    func appDataGroups(runningBundleIDs: Set<String> = []) -> [AppDataGroup] {
        let base = derivedCache.appDataGroups { AppDataIndex.build(outcome: self) }
        return AppDataIndex.applyRunning(base, runningBundleIDs: runningBundleIDs)
    }

    /// `~/Library/Mobile Documents` 인벤토리 (1회 계산 후 캐시).
    func iCloudInventory() -> ICloudInventory {
        derivedCache.iCloud { ICloudInventory.build(outcome: self) }
    }
}
