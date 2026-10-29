import Foundation

/// 선버스트 조각 하나. 각도는 0...1 비율(시작/끝).
public struct SunburstArc: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    /// 논리 경로. "기타" 조각은 부모 경로.
    public let path: String
    /// 1...maxDepth (1 = 가장 안쪽 고리)
    public let depth: Int
    public let start: Double
    public let end: Double
    public let size: Int64
    public let isDirectory: Bool
    public let isOther: Bool
}

/// 선버스트 배치 (PLAN §3-3): 깊이 최대 4, 전체의 0.5% 미만은 "기타"로 합침.
/// 작업 Task 가 취소되면 부분 결과를 돌려주므로 호출자는 취소 시 결과를 버려야 한다.
public enum SunburstLayout {
    public static func arcs(focus: Node, focusPath: String, maxDepth: Int = 4,
                            minFraction: Double = 0.005) -> [SunburstArc] {
        let total = focus.allocatedSize
        guard focus.isDirectory, total > 0 else { return [] }
        let threshold = Int64(Double(total) * minFraction)
        var out: [SunburstArc] = []

        func layout(_ node: Node, path: String, depth: Int, start: Double, end: Double) {
            let denom = max(node.allocatedSize, 1)
            let span = end - start
            var cursor = start
            var otherBytes = node.omittedBytes
            var hadOther = node.omittedBytes > 0
            if Task.isCancelled { return }
            // 임계 미만 자식은 정렬 전에 걸러 "기타"에 합산하고, 살아남은 상위 조각만 정렬한다 (perf-1).
            var big: [Int] = []
            let kids = node.children
            for i in kids.indices {
                let sz = kids[i].allocatedSize
                guard sz > 0 else { continue }
                if sz < threshold { otherBytes += sz; hadOther = true } else { big.append(i) }
            }
            big.sort { a, b in
                kids[a].allocatedSize != kids[b].allocatedSize ? kids[a].allocatedSize > kids[b].allocatedSize
                                                               : kids[a].name < kids[b].name
            }
            for i in big {
                let child = kids[i]
                let childPath = path == "/" ? "/" + child.name : path + "/" + child.name
                let e = cursor + span * Double(child.allocatedSize) / Double(denom)
                out.append(SunburstArc(id: childPath, name: child.name, path: childPath, depth: depth,
                                       start: cursor, end: e, size: child.allocatedSize,
                                       isDirectory: child.isDirectory, isOther: false))
                if child.isDirectory, depth < maxDepth { layout(child, path: childPath, depth: depth + 1, start: cursor, end: e) }
                cursor = e
            }
            if hadOther, otherBytes > 0 {
                let e = min(end, cursor + span * Double(otherBytes) / Double(denom))
                out.append(SunburstArc(id: path + "#other", name: "기타", path: path, depth: depth,
                                       start: cursor, end: e, size: otherBytes, isDirectory: false, isOther: true))
            }
        }
        layout(focus, path: focusPath, depth: 1, start: 0, end: 1)
        return out
    }
}
