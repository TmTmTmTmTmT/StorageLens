import Foundation

/// 정리 버튼 활성/비활성 판단용 표시 정보 (PLAN §16.1 safety 의미). 실제 안전 판정은 Cleaner가 다시 계산한다.
public struct CleanupAvailability: Sendable, Equatable {
    public var path: String
    public var enabled: Bool
    /// 비활성 사유.
    public var reason: String?
    /// nil = 카탈로그 밖 직접 선택 (review 취급).
    public var safety: Safety?
    public var title: String?
    public var method: CleanupMethod
    /// 홈 폴더 밖(시스템 영역) 경로라 정리 불가 (v2 권한 헬퍼 대상).
    public var isOutsideHome: Bool = false

    /// 홈 밖 경로 비활성 사유 (PathSafety 거부 문구와 동일).
    public static let outsideHomeReason = PathSafety.outsideHomeReason

    /// 여러 항목 일괄 정리가 가능한 것은 safe 뿐 (review/카탈로그 밖은 개별 선택만).
    public var isBatchable: Bool { enabled && safety == .safe }
    /// 정리 비권장 항목 (PLAN §16.1): 개별 선택 + 확인 체크 필요.
    public var isDiscouraged: Bool { safety == .discouraged }
}

extension CleanupAvailability {
    /// - Parameter inPersonalFolder: 카탈로그에 없는 경로가 개인 폴더 하위인지 (그렇다면 discouraged).
    static func from(match: CatalogMatch?, path: String, inPersonalFolder: Bool = false) -> CleanupAvailability {
        guard let m = match else {
            return CleanupAvailability(path: path, enabled: true, reason: nil,
                                       safety: inPersonalFolder ? .discouraged : nil, title: nil, method: .trash)
        }
        if m.effectiveMethod == .none || m.entry.method == .none {
            return CleanupAvailability(path: path, enabled: false, reason: m.unavailableReason ?? "정리 방법이 없습니다",
                                       safety: m.entry.safety, title: m.entry.title, method: .none)
        }
        return CleanupAvailability(path: path, enabled: true, reason: nil, safety: m.entry.safety,
                                   title: m.entry.title, method: m.effectiveMethod)
    }
}

extension ScanOutcome {
    /// 경로 항목의 정리 가능 여부 (표시용).
    public func cleanupAvailability(forPath path: String) -> CleanupAvailability {
        if isOutsideHome(path) {
            return CleanupAvailability(path: path, enabled: false, reason: CleanupAvailability.outsideHomeReason,
                                       safety: nil, title: nil, method: .none, isOutsideHome: true)
        }
        let attr = attribution(forPath: path)
        let root = self.root, rootPath = logicalRootPath
        let m = matcher.match(path: path, attribution: attr, modified: { p in
            Self.find(root: root, rootPath: rootPath, path: p)?.modified
        })
        return CleanupAvailability.from(match: m, path: path,
                                        inPersonalFolder: m == nil && matcher.isUnderPersonalFolder(path))
    }

    /// 경로가 세션 홈 밖인지. `/System/Volumes/Data` 접두는 떼고, 홈은 지정값과 realpath 둘 다 비교한다.
    /// 홈 자체·홈 안은 false (홈 자체 거부는 PathSafety가 기존대로 처리). 상대 경로 등은 판단하지 않고 false.
    func isOutsideHome(_ rawPath: String) -> Bool {
        guard rawPath.hasPrefix("/") else { return false }
        func norm(_ p: String) -> String {
            let segs = p.split(separator: "/", omittingEmptySubsequences: true)
            return "/" + segs.joined(separator: "/")
        }
        let path = norm(Self.logicalPath(norm(rawPath)))
        let given = norm(Self.logicalPath(matcher.homePath))
        var homes = [given]
        if let real = try? SystemFileSystem().realPath(of: URL(fileURLWithPath: matcher.homePath)).path {
            homes.append(norm(Self.logicalPath(real)))
        }
        func fold(_ s: String) -> String { PathSafety.fold(s) }
        let fp = fold(path)
        for h in homes {
            let fh = fold(h)
            if fp == fh || fp.hasPrefix(fh + "/") { return false }
        }
        return true
    }

    /// 가상 항목(경로 없는 command 항목)의 실행 가능 여부. 도구가 없으면 "도구 없음".
    public func virtualAvailability(_ entry: CatalogEntry) -> CleanupAvailability {
        CleanupAvailability.from(match: matcher.resolve(entry), path: "virtual:\(entry.id)")
    }
}

/// 정리 기록 화면 한 줄.
public struct JournalRow: Sendable, Identifiable, Equatable {
    public var id: Int
    public var entry: JournalEntry
    public var canUndo: Bool
    public var undoReason: String?
}

extension StorageSession {
    /// Cleaner 생성 (홈 = 이 세션의 홈, 저널 = 기본 위치, 귀속 = 스캔 결과의 Attributor).
    /// - Parameters:
    ///   - outcome: 있으면 고아 판정용 귀속 클로저를 연결. 없으면 귀속 없음.
    ///   - inUse: 정리 시트를 열 때 새로 조회한 InUse 스냅샷.
    public func makeCleaner(outcome: ScanOutcome?, inUse: InUseIndex? = nil) -> Cleaner {
        let locator = ToolLocator(home: home)
        // 매처의 홈은 realpath 기준이어야 Cleaner가 검증한 정규 경로와 패턴이 맞는다.
        let homeReal = (try? SystemFileSystem().realPath(of: home).path) ?? home.standardizedFileURL.path
        let matcher = CatalogMatcher(catalog: catalog, home: homeReal,
                                     toolResolver: { locator.locate($0).map { URL(fileURLWithPath: $0) } })
        let attributor = outcome?.attributorForCleanup
        return Cleaner(home: home, matcher: matcher,
                       attributionLookup: { attributor?.attribute(URL(fileURLWithPath: $0)) },
                       toolLocator: locator, inUse: inUse,
                       journal: Journal.shared(fileURL: Journal.defaultURL(home: home)))
    }

    /// 저널 최신순 + 되돌리기 가능 여부. 파일시스템을 읽으므로 백그라운드에서 호출한다.
    public static func journalRows(cleaner: Cleaner) -> [JournalRow] {
        journalLoad(cleaner: cleaner).rows
    }

    /// `journalRows` + 건너뛴 손상 줄 수.
    public static func journalLoad(cleaner: Cleaner) -> (rows: [JournalRow], corruptLineCount: Int) {
        let read = cleaner.journal.read()
        let rows = read.entries.enumerated().reversed().map { i, e -> JournalRow in
            let (ok, why) = cleaner.canUndo(e)
            return JournalRow(id: i, entry: e, canUndo: ok, undoReason: why)
        }
        return (rows, read.corruptLineCount)
    }

    /// 계획 항목의 도구가 표준 위치 밖(비표준 경로)에서 발견된 것인지 (미리보기 경고용).
    public func isNonStandardTool(_ item: CleanupPlanItem) -> Bool {
        guard item.method == .command, let name = item.toolName, let path = item.toolPath,
              let located = ToolLocator(home: home).locateDetailed(name) else { return false }
        return located.path == path && located.isNonStandard
    }
}

extension ScanOutcome {
    var attributorForCleanup: Attributor { attributor }
}

extension ScanOutcome {
    /// 가상 항목 정리 선택 (예: xcode-sim-unavailable). Cleaner가 카탈로그에서 다시 확인한다.
    public func virtualSelection(_ entry: CatalogEntry) -> CleanupSelection {
        CleanupSelection(virtual: matcher.resolve(entry))
    }
}
