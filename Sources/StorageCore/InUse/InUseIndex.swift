import Foundation

/// 열린 파일 목록 기반 사용 중 질의 (PLAN §7). 정렬 배열 + 이진 탐색.
public struct InUseIndex: InUseQuery {
    private struct Entry: Sendable { let path: String; let name: String }
    private let entries: [Entry]   // path 의 UTF-8 바이트 순 정렬

    public init(records: [OpenFileRecord]) {
        let list = records.map { Entry(path: Self.normalize($0.path), name: $0.processName) }
        self.entries = list.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }

    public static func snapshot(lister: any ProcessLister = SystemProcessLister()) -> InUseIndex {
        InUseIndex(records: lister.openFiles())
    }

    public var count: Int { entries.count }

    public func processes(usingPathPrefix path: String) -> [String] {
        var keys: Set<String> = [Self.normalize(path)]
        // 질의 경로는 심볼릭 링크까지 해석한 형태도 함께 시도
        let resolved = Self.normalize(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        keys.insert(resolved)
        var names = Set<String>()
        for key in keys { collect(key, into: &names) }
        return names.sorted()
    }

    /// 스캔 트리에서 온 경로처럼 이미 심볼릭 링크가 없는 실경로일 때의 질의 (링크 해석 syscall 생략, perf-4).
    /// 결과는 `processes(usingPathPrefix:)` 와 동일하다 (해석 결과가 정규화 후 같은 경로이므로 키 집합이 같다).
    public func processes(usingRealPath path: String) -> [String] {
        var names = Set<String>()
        collect(Self.normalize(path), into: &names)
        return names.sorted()
    }

    private func collect(_ prefix: String, into names: inout Set<String>) {
        let isRoot = prefix == "/"
        let pb = Array(prefix.utf8)
        // lower bound
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].path.utf8.lexicographicallyPrecedes(pb) { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < entries.count {
            let e = entries[i].path.utf8
            guard e.starts(with: pb) else { break }
            if isRoot || e.count == pb.count || e[e.index(e.startIndex, offsetBy: pb.count)] == UInt8(ascii: "/") {
                names.insert(entries[i].name)
            }
            i += 1
        }
    }

    /// 기록·질의 공통 정규화: 표준화 + /private/{var,tmp,etc} 별칭 통일 + 끝 슬래시 제거.
    static func normalize(_ raw: String) -> String {
        var p = (raw as NSString).standardizingPath
        for alias in ["/private/var", "/private/tmp", "/private/etc"] {
            if p == alias || p.hasPrefix(alias + "/") { p = String(p.dropFirst("/private".count)); break }
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
