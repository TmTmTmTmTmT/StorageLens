import Foundation

/// 카탈로그 카테고리 합계 계산 (순수 함수). 트리를 하향 순회하되 카탈로그 패턴과 접두가 맞는 노드만 방문하므로
/// 노드 수가 아니라 패턴 깊이에 비례한다. 일치한 노드는 크기를 해당 항목 id에 더하고 하위로 내려가지 않는다.
/// 단, 더 구체적인 하위 패턴이 있으면 계속 하향하여 그 항목에 귀속시키고 부모 항목에서는 뺀다 (PLAN §6.1).
public enum CategoryTotals {
    public static let otherID = "other"

    /// 고아 추정이 적용되는 `~/Library` 직속 폴더 (PLAN §5.2).
    static let orphanParents = ["Caches", "Application Support", "Containers", "Group Containers", "Preferences",
                                "Logs", "HTTPStorages", "WebKit", "Saved Application State"]

    /// - Parameters:
    ///   - root: 스캔 트리 루트.
    ///   - logicalRootPath: 루트의 논리 경로 (`/System/Volumes/Data` 접두를 뗀 경로. 홈 경로와 비교 가능해야 함).
    ///   - attribute: 고아 판정용 귀속 조회. `~/Library/<위치>` 직속 노드에만 호출된다.
    public static func compute(root: Node, logicalRootPath: String, matcher: CatalogMatcher, home: String,
                               attribute: (@Sendable (String) -> Attribution?)? = nil) -> [String: Int64] {
        let homeSegs = segments(home)
        var patterns: [[String]] = []
        for e in matcher.catalog.entries {
            for p in e.pathPatterns {
                var s = segments(p)
                if p == "~" || p.hasPrefix("~/") { s.removeFirst(); s = homeSegs + s }
                if !s.isEmpty { patterns.append(s) }
            }
        }
        // 고아 위치는 매칭 대상이 아니라 방문 가능성(viability)만 넓힌다.
        let orphanLocations: [[String]] = orphanParents.map { homeSegs + ["Library", $0, "*"] }
        let viablePatterns = patterns + orphanLocations
        let minLen = patterns.map(\.count).min() ?? Int.max

        var totals: [String: Int64] = [:]

        func viable(_ segs: [String]) -> Bool {
            viablePatterns.contains { p in
                for i in 0..<min(p.count, segs.count) where !CatalogMatcher.globMatch(p[i], segs[i]) { return false }
                return true
            }
        }
        func isOrphanLocation(_ segs: [String]) -> Bool {
            orphanLocations.contains { p in
                p.count == segs.count && zip(p, segs).allSatisfy { CatalogMatcher.globMatch($0, $1) }
            }
        }
        /// 카탈로그 패턴 중 이 경로의 엄격한 하위를 가리킬 수 있는 것이 있는가 (고아 위치 제외).
        func hasDeeperPattern(_ segs: [String]) -> Bool {
            patterns.contains { p in
                p.count > segs.count && zip(p, segs).allSatisfy { CatalogMatcher.globMatch($0, $1) }
            }
        }
        /// 하향 중 방문 가치: 길이 이상인 카탈로그 패턴과 접두가 맞을 때만.
        func descentViable(_ segs: [String]) -> Bool {
            patterns.contains { p in
                p.count >= segs.count && zip(p, segs).allSatisfy { CatalogMatcher.globMatch($0, $1) }
            }
        }
        /// - Returns: 이 서브트리에서 항목에 귀속시킨 크기 (부모 항목 합계에서 빼기 위함).
        @discardableResult
        func visit(_ node: Node, path: String, segs: [String], inDescent: Bool = false) -> Int64 {
            if segs.count >= min(minLen, orphanLocations[0].count) {
                let attr = isOrphanLocation(segs) ? attribute?(path) : nil
                let nodeModified = node.modified
                if let m = matcher.match(path: path, attribution: attr, modified: { $0 == path ? nodeModified : nil }),
                   !inDescent || m.matchedRoot == path {
                    if node.isDirectory, hasDeeperPattern(segs) {
                        let claimed = descend(node, path: path, segs: segs, inDescent: true)
                        totals[m.entry.id, default: 0] += node.allocatedSize - claimed
                    } else {
                        totals[m.entry.id, default: 0] += node.allocatedSize
                    }
                    return node.allocatedSize
                }
            }
            guard node.isDirectory else { return 0 }
            return descend(node, path: path, segs: segs, inDescent: inDescent)
        }
        func descend(_ node: Node, path: String, segs: [String], inDescent: Bool) -> Int64 {
            var claimed: Int64 = 0
            for child in node.children {
                let cs = segs + [child.name]
                guard inDescent ? descentViable(cs) : viable(cs) else { continue }
                claimed += visit(child, path: path == "/" ? "/" + child.name : path + "/" + child.name,
                                 segs: cs, inDescent: inDescent)
            }
            // 스캐너가 상위 200개 제한으로 노드에서 뺀 파일(omittedBytes)은 자식 패턴(`dir/*`)이 일치하는 항목에 귀속
            if node.omittedBytes > 0 {
                let ghost = "\u{1}omitted"
                let gs = segs + [ghost]
                let gp = path == "/" ? "/" + ghost : path + "/" + ghost
                if (inDescent ? descentViable(gs) : viable(gs)), gs.count >= min(minLen, orphanLocations[0].count),
                   let m = matcher.match(path: gp, attribution: nil, modified: { _ in nil }), m.matchedRoot == gp {
                    totals[m.entry.id, default: 0] += node.omittedBytes
                    claimed += node.omittedBytes
                }
            }
            return claimed
        }

        _ = visit(root, path: logicalRootPath, segs: segments(logicalRootPath))
        let matched = totals.values.reduce(0, +)
        let rest = root.allocatedSize - matched
        if rest > 0 { totals[otherID] = rest }
        return totals
    }

    static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
