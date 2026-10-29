import Foundation

struct PathRejection: Error { let reason: String }

struct FileIdentity: Hashable, Sendable {
    let dev: Int32
    let ino: UInt64
}

struct VerifiedPath {
    /// 홈 realpath 기준으로 정규화된 경로.
    let path: String
    /// 대상의 lstat 속성. 존재하지 않으면 nil (mustExist == false 일 때만).
    let entry: FileEntry?
    /// 통합 순회로 측정한 할당 크기 합 (링크 미추적, 하드링크 1회). 대상이 없으면 0.
    var measuredSize: Int64 = 0
    /// 순회 중 읽지 못해 크기에 포함되지 않은 항목 수.
    var unmeasuredCount: Int = 0
}

/// 정리 계획/실행의 진행 상황 (UI 표시용). 콜백은 순회 스레드에서 호출되므로 가볍게 처리할 것.
public struct CleanupProgress: Sendable, Equatable {
    /// 현재 대상 안에서 지금까지 확인한 항목 수.
    public var processedCount: Int
    /// 지금 확인 중인 경로.
    public var currentPath: String
    /// 선택/계획 항목 순번 (0부터)과 전체 개수.
    public var itemIndex: Int
    public var itemCount: Int
}
public typealias CleanupProgressHandler = @Sendable (CleanupProgress) -> Void

/// 하위 트리 통합 순회 결과 (.photoslibrary 탐지 + 크기 측정).
struct TreeWalkResult {
    var size: Int64 = 0
    var unmeasured = 0
    var photosFound = false
    /// 읽기 실패(ENOENT 제외)한 첫 폴더 경로.
    var firstUnreadable: String?
}

/// 열거로 얻은 FileEntry(크기·링크 수)를 그대로 재사용하는 단일 순회. 하위 디렉터리만 재귀.
struct TreeWalker {
    let fs: any FileSystem
    var detectPhotos: Bool
    /// true면 읽을 수 없는 폴더를 만나는 즉시 중단한다 (fail-closed).
    var stopOnUnreadable: Bool
    var onVisit: (@Sendable (Int, String) -> Void)?
    /// false면 Task 취소를 무시한다 (실행 후 측정처럼 끝까지 가야 하는 경우).
    var honorCancellation = true

    /// - Throws: `CancellationError` (Task 취소 시)
    func walk(root: URL, rootEntry: FileEntry) throws -> TreeWalkResult {
        var res = TreeWalkResult()
        var seen = Set<FileIdentity>()
        var visited = 0
        res.size = rootEntry.allocatedSize
        if !rootEntry.isDirectory || rootEntry.isSymlink {
            if rootEntry.isSymlink { res.size = 0 }
            return res
        }
        var stack = [root]
        while let dir = stack.popLast() {
            if honorCancellation { try Task.checkCancellation() }
            let kids: [FileEntry]
            do { kids = try fs.entries(in: dir) } catch let e as NSError {
                if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) { continue }   // 경합으로 사라짐
                res.unmeasured += 1
                if res.firstUnreadable == nil { res.firstUnreadable = dir.path }
                if stopOnUnreadable { return res }
                continue
            }
            for k in kids {
                visited += 1
                if visited & 0xFF == 0 {
                    if honorCancellation { try Task.checkCancellation() }
                    onVisit?(visited, dir.appendingPathComponent(k.name).path)
                }
                if detectPhotos, PathSafety.fold(k.name).hasSuffix(PathSafety.photosLibrarySuffix) {
                    res.photosFound = true
                    return res
                }
                if k.isSymlink { continue }
                if k.isDirectory {
                    res.size += k.allocatedSize
                    stack.append(dir.appendingPathComponent(k.name))
                } else {
                    if k.linkCount > 1, !seen.insert(FileIdentity(dev: k.devID, ino: k.inode)).inserted { continue }
                    res.size += k.allocatedSize
                }
            }
        }
        onVisit?(visited, root.path)
        return res
    }
}

/// PLAN §8.1 경로 안전 검사. 실제 삭제/이동 전 plan과 execute 양쪽에서 호출한다.
struct PathSafety: Sendable {
    let home: URL
    let fs: any FileSystem

    /// PLAN §16.2. (홈 기준 상대 경로, 하위 전체 포함 여부).
    /// withDescendants == true: 하드 차단 (자체·하위·상위 폴더 거부).
    /// withDescendants == false: 자체만 차단 (하위 내용은 허용, 상위 규칙 없음).
    static let deniedRoots: [(rel: String, withDescendants: Bool)] = [
        // 하드 차단
        ("Library/Keychains", true), ("Library/Mail", true), ("Library/Messages", true),
        ("Library/Photos", true), ("Library/Mobile Documents", true),
        (".ssh", true), (".gnupg", true),
        // 자체만 차단
        ("Library", false), ("Documents", false), ("Desktop", false), ("Pictures", false),
        ("Movies", false), ("Music", false), ("Downloads", false),
        ("Library/Application Support", false), ("Library/Containers", false),
        ("Library/Group Containers", false), ("Library/Caches", false), ("Library/Preferences", false),
        (".cache", false),
    ]
    static let photosLibrarySuffix = ".photoslibrary"
    static let mobileDocumentsRel = "Library/Mobile Documents"

    /// 홈 밖 경로 거부/비활성 사유 (사용자 문구).
    static let outsideHomeReason = "시스템 영역(홈 폴더 밖)은 이 앱에서 정리할 수 없습니다. Finder에서 직접 삭제하세요(관리자 암호 필요)."

    static func fold(_ s: String) -> String { s.decomposedStringWithCanonicalMapping.lowercased() }

    private static func normalizedSegments(_ p: String) -> [String] {
        p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    func homeRealPath() throws -> String {
        do { return try fs.realPath(of: home).path } catch { throw PathRejection(reason: "홈 디렉터리를 확인할 수 없음") }
    }

    func mobileDocumentsPath() throws -> String { try homeRealPath() + "/" + Self.mobileDocumentsRel }

    /// 보호 경로 identity. 존재하지 않음(ENOENT)이면 nil, 그 밖의 조회 실패는 거부 (fail-closed).
    private func identity(_ path: String) throws -> FileIdentity? {
        do {
            let a = try fs.attributes(at: URL(fileURLWithPath: path))
            return FileIdentity(dev: a.devID, ino: a.inode)
        } catch let e as NSError {
            if e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) { return nil }
            throw PathRejection(reason: "보호 경로를 확인할 수 없어 안전 확인 불가: \(path)")
        }
    }

    /// 경로를 검사한다. 통과 못 하면 `PathRejection`.
    /// - Parameter onVisit: 하위 순회 진행 콜백 (확인한 항목 수, 현재 경로).
    func verify(_ rawPath: String, method: CleanupMethod, mustExist: Bool = true,
                onVisit: (@Sendable (Int, String) -> Void)? = nil) throws -> VerifiedPath {
        guard rawPath.hasPrefix("/") else { throw PathRejection(reason: "절대 경로가 아님") }
        let comps = Self.normalizedSegments(rawPath)
        if comps.contains("..") || comps.contains(".") { throw PathRejection(reason: "경로에 . 또는 .. 포함") }
        var path = "/" + comps.joined(separator: "/")
        let homeGiven = "/" + Self.normalizedSegments(home.path).joined(separator: "/")
        let homeReal = try homeRealPath()
        if path == homeGiven || path.hasPrefix(homeGiven + "/") {
            path = homeReal + String(path.dropFirst(homeGiven.count))
        }
        if Self.fold(path) == Self.fold(homeReal) { throw PathRejection(reason: "홈 디렉터리 자체는 정리할 수 없음") }
        guard path.hasPrefix(homeReal + "/") else { throw PathRejection(reason: Self.outsideHomeReason) }

        if method == .none { throw PathRejection(reason: "정리 방법 없음") }

        // 각 컴포넌트 lstat: 심볼릭 링크 거부, (dev, inode) 수집.
        let rel = Array(path.dropFirst(homeReal.count + 1).split(separator: "/", omittingEmptySubsequences: true).map(String.init))
        var cur = homeReal
        var ids: [FileIdentity] = []
        var lastEntry: FileEntry?
        var lastMissing = false
        for (i, c) in rel.enumerated() {
            cur += "/" + c
            do {
                let a = try fs.attributes(at: URL(fileURLWithPath: cur))
                if a.isSymlink { throw PathRejection(reason: "경로에 심볼릭 링크 포함: \(cur)") }
                ids.append(FileIdentity(dev: a.devID, ino: a.inode))
                lastEntry = a
            } catch let r as PathRejection {
                throw r
            } catch let e as NSError {
                let notFound = e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT)
                if notFound && !mustExist && i == rel.count - 1 { lastMissing = true; lastEntry = nil; break }
                throw PathRejection(reason: notFound ? "대상이 존재하지 않음" : "대상을 확인할 수 없음: \(e.localizedDescription)")
            }
        }
        if !lastMissing {
            guard let rp = try? fs.realPath(of: URL(fileURLWithPath: path)).path, rp == path else {
                throw PathRejection(reason: "정규 경로가 아님 (realpath 불일치)")
            }
        }

        // `.photoslibrary` 컴포넌트가 있는 경로(자체·하위)는 어떤 방법으로도 거부.
        if rel.contains(where: { Self.fold($0).hasSuffix(Self.photosLibrarySuffix) }) {
            throw PathRejection(reason: "사진 라이브러리(.photoslibrary)는 정리할 수 없음")
        }

        let lastID: FileIdentity? = lastMissing ? nil : ids.last
        let strictAncestors: [FileIdentity] = lastMissing ? ids : Array(ids.dropLast())
        let np = Self.fold(path)
        for d in Self.deniedRoots {
            let dpath = homeReal + "/" + d.rel
            let dp = Self.fold(dpath)
            let isMD = d.rel == Self.mobileDocumentsRel
            var selfHit = np == dp
            var descHit = d.withDescendants && np.hasPrefix(dp + "/")
            var ancestorHit = d.withDescendants && dp.hasPrefix(np + "/")
            if let did = try identity(dpath) {
                if let l = lastID, l == did { selfHit = true }
                if d.withDescendants, strictAncestors.contains(did) { descHit = true }
                if d.withDescendants, let l = lastID {
                    // 거부 경로의 상위 폴더 (홈 포함) 중에 선택 경로가 있으면 상위 폴더 선택.
                    var anc: [FileIdentity] = []
                    var p = homeReal
                    if let h = try identity(p) { anc.append(h) }
                    for c in d.rel.split(separator: "/").dropLast() {
                        p += "/" + c
                        if let i = try identity(p) { anc.append(i) }
                    }
                    if anc.contains(l) { ancestorHit = true }
                }
            }
            if isMD && method == .icloudEvict && (selfHit || descHit) && !ancestorHit { continue }
            if selfHit || descHit {
                throw PathRejection(reason: d.withDescendants ? "보호 경로: ~/\(d.rel)" : "보호 폴더 자체는 정리할 수 없음: ~/\(d.rel) (하위 항목은 개별 선택)")
            }
            if ancestorHit { throw PathRejection(reason: "보호 경로(~/\(d.rel))를 포함하는 상위 폴더") }
        }

        if method == .icloudEvict {
            let md = Self.fold(homeReal + "/" + Self.mobileDocumentsRel)
            guard np == md || np.hasPrefix(md + "/") else {
                throw PathRejection(reason: "iCloud Drive 경로가 아님 (icloudEvict는 Mobile Documents만 허용)")
            }
        }
        // 하위 통합 순회 (.photoslibrary 탐지 + 크기 측정, 심볼릭 링크 미추적). 읽을 수 없는 폴더는 거부.
        var out = VerifiedPath(path: path, entry: lastEntry)
        if let e = lastEntry {
            let walker = TreeWalker(fs: fs, detectPhotos: true, stopOnUnreadable: true, onVisit: onVisit)
            let w: TreeWalkResult
            do { w = try walker.walk(root: URL(fileURLWithPath: path), rootEntry: e) }
            catch is CancellationError { throw PathRejection(reason: "취소됨") }
            if w.photosFound {
                throw PathRejection(reason: "사진 라이브러리(.photoslibrary)를 포함한 폴더는 정리할 수 없음")
            }
            if w.firstUnreadable != nil {
                throw PathRejection(reason: "하위 폴더를 읽을 수 없어 안전 확인 불가")
            }
            out.measuredSize = w.size
            out.unmeasuredCount = w.unmeasured
        }
        return out
    }

    /// 하위 순회로 `.photoslibrary` 이름의 항목을 찾는다. 링크는 따라가지 않는다.
    /// 읽을 수 없는 폴더(ENOENT 제외)가 있으면 확인 불가이므로 `PathRejection`을 던진다 (fail-closed).
    func containsPhotosLibrary(under root: String) throws -> Bool {
        let url = URL(fileURLWithPath: root)
        let e = try fs.attributes(at: url)
        let w = try TreeWalker(fs: fs, detectPhotos: true, stopOnUnreadable: true, onVisit: nil)
            .walk(root: url, rootEntry: e)
        if w.photosFound { return true }
        if w.firstUnreadable != nil { throw PathRejection(reason: "하위 폴더를 읽을 수 없어 안전 확인 불가") }
        return false
    }
}
