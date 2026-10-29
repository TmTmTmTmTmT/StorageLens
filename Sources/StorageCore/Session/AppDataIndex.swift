import Foundation

/// 앱 데이터 위치 종류 (UI는 한글 라벨 문자열이 아니라 이 식별자로 판별한다).
public enum AppDataLocationKind: String, Sendable, Equatable, Codable, CaseIterable {
    case caches, applicationSupport, containers, groupContainers, logs, preferences
    case savedState, httpStorages, webKit, devCache

    /// 한국어 표시 이름.
    public var label: String {
        switch self {
        case .caches: return "캐시"
        case .applicationSupport: return "앱 데이터"
        case .containers: return "컨테이너"
        case .groupContainers: return "그룹 컨테이너"
        case .logs: return "로그"
        case .preferences: return "설정"
        case .savedState: return "저장된 창 상태"
        case .httpStorages: return "HTTP 저장소"
        case .webKit: return "WebKit 데이터"
        case .devCache: return "개발 도구 캐시"
        }
    }

    /// "캐시만 선택" 대상.
    public var isCache: Bool { self == .caches || self == .devCache }
}

/// 앱 데이터 묶음의 항목 한 개 (PLAN §16.3).
public struct AppDataItem: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var name: String
    /// 위치 종류 식별자.
    public var kind: AppDataLocationKind
    /// 한국어 위치 종류 라벨 (`kind.label`).
    public var locationKind: String { kind.label }
    public var size: Int64
    public var modified: Date
    /// 카탈로그 일치 항목의 안전 등급. 일치 없으면 nil.
    public var safety: Safety?
    public var catalogTitle: String?
    /// 이 항목을 열고 있는 프로세스 이름 (InUse).
    public var inUseBy: [String]
}

/// 앱 한 개(또는 macOS 시스템·알 수 없음)의 데이터 묶음.
public struct AppDataGroup: Sendable, Equatable, Identifiable {
    public var id: String
    public var appName: String
    public var bundleID: String?
    public var iconSource: IconSource
    public var totalBytes: Int64
    public var items: [AppDataItem]
    public var isRunning: Bool
    public var isOrphanSuspect: Bool
    public var isSystem: Bool
    /// 스캐너의 디렉터리당 상위 200개 제한으로 일부 파일이 생략되어 합계에 `omittedBytes`만 반영됨 (UI: "일부 파일 생략").
    public var hasOmittedFiles: Bool = false
    /// 항목으로 나열되지 않고 합계에만 반영된 생략 바이트.
    public var omittedBytes: Int64 = 0
    /// 같은 제조사 앱이 여러 개라 특정 앱에 귀속하지 않은 제조사 공용 묶음 (id = "vendor:<token>").
    public var isVendorShared: Bool { id.hasPrefix(Attributor.vendorGroupPrefix) }
}

/// 스캔 결과에서 앱별 데이터 묶음을 계산한다. 순수 함수 (PLAN §16.3).
public enum AppDataIndex {
    public static let systemKey = "macOS 시스템"
    public static let unknownKey = "알 수 없음"

    /// (홈 기준 상대 경로, 위치 종류)
    static let locations: [(rel: String, kind: AppDataLocationKind)] = [
        ("Library/Caches", .caches),
        ("Library/Application Support", .applicationSupport),
        ("Library/Containers", .containers),
        ("Library/Group Containers", .groupContainers),
        ("Library/Logs", .logs),
        ("Library/Preferences", .preferences),
        ("Library/Saved Application State", .savedState),
        ("Library/HTTPStorages", .httpStorages),
        ("Library/WebKit", .webKit),
        (".cache", .devCache),
    ]

    static func build(outcome: ScanOutcome) -> [AppDataGroup] {
        let home = outcome.matcher.homePath
        let root = outcome.root, rootPath = outcome.logicalRootPath
        let attributor = outcome.attributor, matcher = outcome.matcher, inUse = outcome.inUse
        return build(root: root, logicalRootPath: rootPath, home: home,
                     attribute: { attributor.attribute(URL(fileURLWithPath: $0)) },
                     match: { path, attr in
                         matcher.match(path: path, attribution: attr, modified: { p in
                             ScanOutcome.find(root: root, rootPath: rootPath, path: p)?.modified
                         })
                     },
                     inUse: { inUse.processes(usingPathPrefix: $0) })
    }

    /// 순수 계산. 실행 중 표시는 `applyRunning`에서 덧씌운다 (여기서는 InUse만 반영).
    static func build(root: Node, logicalRootPath: String, home: String,
                      attribute: (String) -> Attribution,
                      match: (String, Attribution) -> CatalogMatch?,
                      inUse: (String) -> [String]) -> [AppDataGroup] {
        var groups: [String: AppDataGroup] = [:]
        for loc in locations {
            let dir = home + "/" + loc.rel
            guard let parent = ScanOutcome.find(root: root, rootPath: logicalRootPath, path: dir) else { continue }
            // 스캐너가 직속 파일을 상위 200개로 줄였다면 생략분을 "알 수 없음" 합계에 반영 (항목 없음)
            if parent.omittedBytes > 0 {
                var g = groups[unknownKey] ?? AppDataGroup(
                    id: unknownKey, appName: unknownKey, bundleID: nil, iconSource: .none,
                    totalBytes: 0, items: [], isRunning: false, isOrphanSuspect: false, isSystem: false)
                g.totalBytes += parent.omittedBytes
                g.omittedBytes += parent.omittedBytes
                g.hasOmittedFiles = true
                groups[unknownKey] = g
            }
            for child in parent.children {
                let path = dir + "/" + child.name
                let attr = attribute(path)
                let m = match(path, attr)
                let users = inUse(path)
                let item = AppDataItem(path: path, name: child.name, kind: loc.kind,
                                       size: child.allocatedSize, modified: child.modified,
                                       safety: m?.entry.safety, catalogTitle: m?.entry.title, inUseBy: users)

                let isSystem = (attr.bundleID?.lowercased().hasPrefix("com.apple.") ?? false) || attr.appName == systemKey
                let key: String
                if isSystem { key = systemKey }
                else if let b = attr.bundleID, !b.isEmpty { key = b }
                else { key = attr.appName.isEmpty ? unknownKey : attr.appName }
                // ~/.cache 직속 자식이 귀속 "알 수 없음"이면 폴더 이름별 묶음 (예: uv, codex-runtimes)
                let isUnknown = !isSystem && (attr.bundleID?.isEmpty ?? true) && (attr.appName.isEmpty || attr.appName == unknownKey)
                let cacheSplit = loc.rel == ".cache" && isUnknown
                let key2 = cacheSplit ? "cache:" + child.name : key

                var g = groups[key2] ?? AppDataGroup(
                    id: key2, appName: cacheSplit ? child.name : (isSystem ? systemKey : (attr.appName.isEmpty ? unknownKey : attr.appName)),
                    bundleID: (isSystem || key2.hasPrefix(Attributor.vendorGroupPrefix)) ? nil : attr.bundleID,
                    iconSource: isSystem ? .symbol("gearshape") : attr.iconSource,
                    totalBytes: 0, items: [], isRunning: false, isOrphanSuspect: false, isSystem: isSystem)
                if g.iconSource == .none, attr.iconSource != .none, !isSystem { g.iconSource = attr.iconSource }
                g.totalBytes += item.size
                g.items.append(item)
                if !users.isEmpty { g.isRunning = true }
                if attr.isOrphanSuspect { g.isOrphanSuspect = true }
                groups[key2] = g
            }
        }
        var out = Array(groups.values)
        for i in out.indices {
            out[i].items.sort { $0.size != $1.size ? $0.size > $1.size : $0.path < $1.path }
        }
        out.sort {
            if $0.isSystem != $1.isSystem { return !$0.isSystem }
            return $0.totalBytes != $1.totalBytes ? $0.totalBytes > $1.totalBytes : $0.appName < $1.appName
        }
        return out
    }

    /// 실행 중 앱 번들 ID(대소문자 무시)를 덧씌운다.
    static func applyRunning(_ groups: [AppDataGroup], runningBundleIDs: Set<String>) -> [AppDataGroup] {
        if runningBundleIDs.isEmpty { return groups }
        let lower = Set(runningBundleIDs.map { $0.lowercased() })
        return groups.map { g in
            var g = g
            if let b = g.bundleID, lower.contains(b.lowercased()) { g.isRunning = true }
            // 제조사 공용 묶음: 해당 제조사 앱이 하나라도 실행 중이면 표시
            if g.isVendorShared {
                let token = String(g.id.dropFirst(Attributor.vendorGroupPrefix.count))
                if lower.contains(where: { $0.split(separator: ".").dropFirst().first.map(String.init) == token }) {
                    g.isRunning = true
                }
            }
            return g
        }
    }
}
