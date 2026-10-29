import Foundation

/// 카탈로그 항목 집합 (PLAN §6). `Resources/catalog.json`을 Data로 받아 로드한다.
public struct Catalog: Sendable, Equatable {
    public static let orphanID = "orphan"
    public static let huggingFaceNote = "공유 저장소 구조라 모델 폴더만 지우면 공간이 거의 안 빠지고 다른 모델이 깨질 수 있습니다. 정리는 `hf cache` 명령 또는 각 앱에서 하는 것을 권장합니다."

    public let entries: [CatalogEntry]

    public init(entries: [CatalogEntry]) { self.entries = entries }

    public static func load(from data: Data) throws -> Catalog {
        Catalog(entries: try JSONDecoder().decode([CatalogEntry].self, from: data))
    }

    public func entry(id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    /// 경로 없는 가상 항목 (예: xcode-sim-unavailable). orphan은 제외.
    public var virtualEntries: [CatalogEntry] {
        entries.filter { $0.pathPatterns.isEmpty && $0.id != Catalog.orphanID }
    }
}

/// 매칭 결과.
public struct CatalogMatch: Sendable, Equatable {
    public var entry: CatalogEntry
    /// 패턴과 일치한 상위 경로 (정리 단위). 질의 경로가 정확히 일치하면 질의 경로 자신.
    public var matchedRoot: String
    /// 도구 해석 후 실제 정리 방법.
    public var effectiveMethod: CleanupMethod
    /// effectiveMethod가 entry.method와 달라진 이유 (예: "도구 없음").
    public var unavailableReason: String?
    /// command 항목의 해석된 실행 파일.
    public var toolURL: URL?
}

/// 경로 -> 카탈로그 항목 매처 (PLAN §6.1).
public struct CatalogMatcher: Sendable {
    public typealias ToolResolver = @Sendable (String) -> URL?
    /// matchedRoot 경로의 수정일. 알 수 없으면 nil.
    public typealias ModifiedLookup = @Sendable (String) -> Date?

    public let catalog: Catalog
    private let home: [String]
    /// 매처가 패턴의 `~`를 확장할 때 쓰는 홈 경로 (정규화된 절대 경로).
    public var homePath: String { "/" + home.joined(separator: "/") }
    private let clock: any Clock
    private let resolveTool: ToolResolver

    public init(catalog: Catalog, home: String, clock: any Clock = SystemClock(),
                toolResolver: @escaping ToolResolver) {
        self.catalog = catalog
        self.home = CatalogMatcher.segments(home)
        self.clock = clock
        self.resolveTool = toolResolver
    }

    /// - Parameters:
    ///   - path: 절대 경로.
    ///   - attribution: 고아 추정 판정용.
    ///   - modified: minAgeDays 판정용 수정일 조회 (matchedRoot를 인자로 호출). 모르면 minAgeDays 항목은 불일치.
    /// - Returns: 일치 없음이면 nil (UI가 review 취급).
    public func match(path: String, attribution: Attribution? = nil,
                      modified: ModifiedLookup? = nil) -> CatalogMatch? {
        let segs = CatalogMatcher.segments(path)
        if attribution?.isOrphanSuspect == true, let orphan = catalog.entry(id: Catalog.orphanID) {
            return makeMatch(orphan, root: path)
        }
        struct Candidate { var entry: CatalogEntry; var rootLen: Int; var score: [Int] }
        var best: Candidate?
        for entry in catalog.entries where entry.id != Catalog.orphanID {
            if excluded(entry, segs) { continue }
            for raw in entry.pathPatterns {
                let pat = expand(raw)
                guard pat.count <= segs.count, !pat.isEmpty else { continue }
                guard zip(pat, segs).allSatisfy({ CatalogMatcher.globMatch($0, $1) }) else { continue }
                let rootPath = "/" + segs.prefix(pat.count).joined(separator: "/")
                if let days = entry.minAgeDays {
                    guard let m = modified?(rootPath),
                          clock.now.timeIntervalSince(m) >= Double(days) * 86400 else { continue }
                }
                let literalSegs = pat.filter { !$0.contains("*") }
                let score = [literalSegs.count, pat.count, pat.reduce(0) { $0 + $1.filter { $0 != "*" }.count }]
                if best == nil || best!.score.lexicographicallyPrecedes(score) {
                    best = Candidate(entry: entry, rootLen: pat.count, score: score)
                }
            }
        }
        guard let b = best else { return nil }
        let root = "/" + segs.prefix(b.rootLen).joined(separator: "/")
        return makeMatch(b.entry, root: root)
    }

    /// 개인 폴더(Documents/Desktop/Pictures/Movies/Music) 하위 경로인가 (PLAN §16.1: 카탈로그 밖이면 discouraged).
    public static let personalFolders = ["Documents", "Desktop", "Pictures", "Movies", "Music"]
    public func isUnderPersonalFolder(_ path: String) -> Bool {
        let segs = CatalogMatcher.segments(path).map { $0.decomposedStringWithCanonicalMapping.lowercased() }
        guard segs.count > home.count + 1 else { return false }
        let h = home.map { $0.decomposedStringWithCanonicalMapping.lowercased() }
        guard Array(segs.prefix(h.count)) == h else { return false }
        return CatalogMatcher.personalFolders.contains { $0.lowercased() == segs[h.count] }
    }

    /// command 항목의 도구 해석 (경로 없는 가상 항목에도 사용).
    public func resolve(_ entry: CatalogEntry, root: String = "") -> CatalogMatch {
        makeMatch(entry, root: root)
    }

    private func makeMatch(_ entry: CatalogEntry, root: String) -> CatalogMatch {
        guard entry.method == .command else {
            return CatalogMatch(entry: entry, matchedRoot: root, effectiveMethod: entry.method)
        }
        if let tool = entry.command?.tool, let url = resolveTool(tool) {
            return CatalogMatch(entry: entry, matchedRoot: root, effectiveMethod: .command, toolURL: url)
        }
        return CatalogMatch(entry: entry, matchedRoot: root, effectiveMethod: .none, unavailableReason: "도구 없음")
    }

    private func excluded(_ entry: CatalogEntry, _ segs: [String]) -> Bool {
        for raw in entry.excludePatterns {
            let pat = expand(raw)
            if !pat.isEmpty, pat.count <= segs.count,
               zip(pat, segs).allSatisfy({ CatalogMatcher.globMatch($0, $1) }) { return true }
        }
        return false
    }

    private func expand(_ pattern: String) -> [String] {
        var s = CatalogMatcher.segments(pattern)
        if pattern == "~" || pattern.hasPrefix("~/") { s.removeFirst(); s = home + s }
        return s
    }

    static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// 한 세그먼트 안에서 `*`는 임의 문자열(0자 이상).
    static func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if pi < p.count, p[pi] == t[ti] { pi += 1; ti += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
