import Foundation

/// 진행 스트림 + 결과 태스크. 취소는 `result.cancel()`.
public struct ScanHandle: Sendable {
    public let progress: AsyncStream<ScanProgress>
    public let result: Task<ScanResult, Error>
}

/// 디렉터리 트리 스캐너 (PLAN §4).
public final class Scanner: Sendable {
    public static let maxFilesPerDirectory = 200

    private let fileSystem: any FileSystem
    private let concurrency: Int
    private let fullKeepDirectories: Set<String>

    /// - Parameter fullKeepDirectories: 직속 파일을 상위 200개 제한 없이 전부 노드로 유지할 디렉터리의 절대 경로 집합.
    ///   기본값은 실제 홈 기준 `AppDataIndex.locations`(Preferences 등)이다 (`defaultFullKeepDirectories`).
    public init(fileSystem: any FileSystem = SystemFileSystem(),
                concurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                fullKeepDirectories: Set<String> = Scanner.defaultFullKeepDirectories()) {
        self.fileSystem = fileSystem
        self.concurrency = max(1, concurrency)
        self.fullKeepDirectories = fullKeepDirectories
    }

    /// 앱별 데이터 화면이 쓰는 위치(`AppDataIndex.locations`)의 절대 경로. 논리 경로와 `/System/Volumes/Data` 접두 경로를 모두 포함.
    public static func defaultFullKeepDirectories(home: String = NSHomeDirectory()) -> Set<String> {
        var out = Set<String>()
        var homes = [home]
        if let r = realpath(home, nil) { homes.append(String(cString: r)); free(r) }
        for h in homes {
            for loc in AppDataIndex.locations {
                let p = h + "/" + loc.rel
                out.insert(p)
                out.insert("/System/Volumes/Data" + p)
            }
        }
        return out
    }

    /// 스캔 시작. 진행 스트림과 결과 태스크를 반환.
    public func start(root: URL) -> ScanHandle {
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let fs = fileSystem
        let n = concurrency
        let keep = fullKeepDirectories
        let task = Task<ScanResult, Error>.detached {
            defer { continuation.finish() }
            let run = ScanRun(fileSystem: fs, concurrency: n, fullKeep: keep, continuation: continuation)
            return try await withTaskCancellationHandler {
                try run.execute(root: root)
            } onCancel: {
                run.cancel()
            }
        }
        return ScanHandle(progress: stream, result: task)
    }

    /// 진행 보고 없이 결과만 필요할 때.
    public func scan(root: URL) async throws -> ScanResult {
        let h = start(root: root)
        return try await withTaskCancellationHandler {
            try await h.result.value
        } onCancel: { h.result.cancel() }
    }
}

// MARK: - 내부 구현

private struct HardLinkKey: Hashable { let dev: Int32; let inode: UInt64 }

/// 하드링크 후보: 스캔 후 단일 스레드에서 경로 사전순 최솟값에만 크기를 배정한다.
private struct LinkCandidate {
    var record: Int
    var dirPath: String
    var entry: FileEntry
    var filePath: String { dirPath == "/" ? "/" + entry.name : dirPath + "/" + entry.name }
}

private struct DirRecord {
    var name: String
    var entry: FileEntry
    var fileNodes: [Node] = []
    var childDirs: [Int] = []
    var parent: Int
    var fileAlloc: Int64 = 0
    var fileLogical: Int64 = 0
    var omittedCount = 0
    var omittedBytes: Int64 = 0
}

private final class ScanRun: @unchecked Sendable {
    let fs: any FileSystem
    let concurrency: Int
    let continuation: AsyncStream<ScanProgress>.Continuation

    // cond가 보호: records, queue, active, skipped, cancelled, itemCount, bytes, lastReported
    let cond = NSCondition()
    var records: [DirRecord] = []
    var queue: [(index: Int, path: String)] = []
    var active = 0
    var skipped: [String] = []
    var cancelled = false
    var itemCount = 0
    var bytes: Int64 = 0
    var lastReported = 0

    let linkLock = NSLock()
    var linkCandidates: [HardLinkKey: [LinkCandidate]] = [:]
    var rootDev: Int32 = 0
    let fullKeep: Set<String>

    init(fileSystem: any FileSystem, concurrency: Int, fullKeep: Set<String>,
         continuation: AsyncStream<ScanProgress>.Continuation) {
        self.fs = fileSystem; self.concurrency = concurrency; self.continuation = continuation
        self.fullKeep = fullKeep
    }

    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    func execute(root: URL) throws -> ScanResult {
        let started = Date()
        var rootURL = root
        if let real = try? fs.realPath(of: root) { rootURL = real }
        let rootEntry = try fs.attributes(at: rootURL)
        rootDev = rootEntry.devID
        let rootPath = rootURL.path
        guard rootEntry.isDirectory else {
            let node = Node(name: rootPath, isDirectory: false, allocatedSize: rootEntry.allocatedSize,
                            logicalSize: rootEntry.logicalSize, inode: rootEntry.inode, devID: rootEntry.devID,
                            linkCount: rootEntry.linkCount, modified: rootEntry.modified,
                            isDataless: rootEntry.isDataless, ownerUID: rootEntry.ownerUID)
            return ScanResult(rootPath: rootPath, root: node, skipped: [], startedAt: started, finishedAt: Date())
        }

        records.append(DirRecord(name: rootPath, entry: rootEntry, parent: -1))
        queue.append((0, rootPath))

        DispatchQueue.concurrentPerform(iterations: concurrency) { _ in worker() }

        if cancelled { throw CancellationError() }
        resolveHardLinks()
        continuation.yield(ScanProgress(itemCount: itemCount, bytes: bytes, currentPath: rootPath))
        let rootNode = assemble()
        return ScanResult(rootPath: rootPath, root: rootNode, skipped: skipped.sorted(),
                          startedAt: started, finishedAt: Date())
    }

    private func worker() {
        while true {
            cond.lock()
            while queue.isEmpty && active > 0 && !cancelled { cond.wait() }
            if cancelled || queue.isEmpty {
                cond.broadcast(); cond.unlock(); return
            }
            let item = queue.removeLast()
            active += 1
            cond.unlock()

            process(item.index, item.path)

            cond.lock()
            active -= 1
            cond.broadcast()
            cond.unlock()
        }
    }

    private func process(_ index: Int, _ path: String) {
        let list: [FileEntry]
        do {
            list = try fs.entries(in: URL(fileURLWithPath: path, isDirectory: true))
        } catch {
            let code = (error as NSError).code
            if (error as NSError).domain == NSPOSIXErrorDomain, code == Int(ENOENT) { return }
            cond.lock(); skipped.append(path); cond.unlock()
            return
        }

        let excludeSystem = (path == "/System")
        let keepAll = fullKeep.contains(path)
        let limit = Scanner.maxFilesPerDirectory
        var subdirs: [FileEntry] = []
        var kept: [FileEntry] = []          // keepAll이면 전체, 아니면 상위 limit개 힙 (최소 크기가 루트)
        var fileAlloc: Int64 = 0, fileLogical: Int64 = 0
        var fileCount = 0
        var count = 0
        var pendingLinks: [FileEntry] = []

        for e in list {
            if excludeSystem && !(e.isDirectory && e.name == "Volumes") { continue }
            count += 1
            if e.isDirectory { subdirs.append(e); continue }
            if e.linkCount > 1 {
                // 하드링크: 귀속 폴더는 스캔 후 결정적으로 정한다 (이 단계에서는 합계에 넣지 않음)
                pendingLinks.append(e)
                continue
            }
            fileAlloc += e.allocatedSize; fileLogical += e.logicalSize
            fileCount += 1
            if keepAll || kept.count < limit {
                kept.append(e)
                if !keepAll && kept.count == limit { Self.heapify(&kept) }
            } else if Self.worse(kept[0], than: e) {
                kept[0] = e
                Self.siftDown(&kept, 0)
            }
        }

        var files: [Node] = kept.map { e in
            Node(name: e.name, isDirectory: false, allocatedSize: e.allocatedSize, logicalSize: e.logicalSize,
                 inode: e.inode, devID: e.devID, linkCount: e.linkCount, modified: e.modified,
                 isDataless: e.isDataless, ownerUID: e.ownerUID)
        }
        files.sort { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.name < $1.name }
        let keptAlloc = files.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let omittedCount = fileCount - files.count
        let omittedBytes = fileAlloc - keptAlloc

        cond.lock()
        var childIdx: [Int] = []
        for d in subdirs {
            let idx = records.count
            records.append(DirRecord(name: d.name, entry: d, parent: index))
            childIdx.append(idx)
            if d.devID == rootDev && !d.isSymlink {
                queue.append((idx, path == "/" ? "/" + d.name : path + "/" + d.name))
            }
        }
        records[index].fileNodes = files
        records[index].childDirs = childIdx
        records[index].fileAlloc = fileAlloc
        records[index].fileLogical = fileLogical
        records[index].omittedCount = omittedCount
        records[index].omittedBytes = omittedBytes
        if !pendingLinks.isEmpty {
            linkLock.lock()
            for e in pendingLinks {
                linkCandidates[HardLinkKey(dev: e.devID, inode: e.inode), default: []]
                    .append(LinkCandidate(record: index, dirPath: path, entry: e))
            }
            linkLock.unlock()
        }
        itemCount += count
        bytes += fileAlloc
        var report: ScanProgress?
        if itemCount - lastReported >= 1000 {
            lastReported = itemCount
            report = ScanProgress(itemCount: itemCount, bytes: bytes, currentPath: path)
        }
        cond.broadcast()
        cond.unlock()
        if let report { continuation.yield(report) }
    }

    /// 스캔 종료 후 단일 스레드: (dev, inode)별로 경로 사전순 최솟값 후보의 폴더에만 크기를 배정, 나머지는 0.
    private func resolveHardLinks() {
        for (_, cands) in linkCandidates {
            var winner = 0
            if cands.count > 1 {
                var best = cands[0].filePath
                for i in 1..<cands.count {
                    let p = cands[i].filePath
                    if p < best { best = p; winner = i }
                }
            }
            for (i, c) in cands.enumerated() {
                let e = c.entry
                let alloc = i == winner ? e.allocatedSize : 0
                let logical = i == winner ? e.logicalSize : 0
                records[c.record].fileNodes.append(
                    Node(name: e.name, isDirectory: false, allocatedSize: alloc, logicalSize: logical,
                         inode: e.inode, devID: e.devID, linkCount: e.linkCount, modified: e.modified,
                         isDataless: e.isDataless, ownerUID: e.ownerUID))
                records[c.record].fileAlloc += alloc
                records[c.record].fileLogical += logical
                bytes += alloc
            }
        }
        linkCandidates = [:]
    }

    // MARK: 상위 N 부분 선택 (최소 힙: 루트 = 가장 "나쁜" 항목 = 작은 크기, 동률이면 이름이 큰 쪽)

    /// a가 b보다 순위가 낮은가 (유지 우선순위: 크기 큼, 동률이면 이름 작음).
    private static func worse(_ a: FileEntry, than b: FileEntry) -> Bool {
        a.allocatedSize != b.allocatedSize ? a.allocatedSize < b.allocatedSize : a.name > b.name
    }
    private static func heapify(_ h: inout [FileEntry]) {
        var i = h.count / 2 - 1
        while i >= 0 { siftDown(&h, i); i -= 1 }
    }
    private static func siftDown(_ h: inout [FileEntry], _ start: Int) {
        var i = start
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < h.count, worse(h[l], than: h[m]) { m = l }
            if r < h.count, worse(h[r], than: h[m]) { m = r }
            if m == i { return }
            h.swapAt(i, m); i = m
        }
    }

    private func assemble() -> Node {
        var nodes = [Node?](repeating: nil, count: records.count)
        for i in stride(from: records.count - 1, through: 0, by: -1) {
            let r = records[i]
            var alloc = r.fileAlloc, logical = r.fileLogical
            var children = r.fileNodes
            for c in r.childDirs {
                if let n = nodes[c] {
                    alloc += n.allocatedSize; logical += n.logicalSize
                    children.append(n)
                    nodes[c] = nil
                }
            }
            nodes[i] = Node(name: r.name, isDirectory: true, allocatedSize: alloc, logicalSize: logical,
                            inode: r.entry.inode, devID: r.entry.devID, linkCount: r.entry.linkCount,
                            modified: r.entry.modified, isDataless: r.entry.isDataless,
                            ownerUID: r.entry.ownerUID, children: children,
                            omittedFileCount: r.omittedCount, omittedBytes: r.omittedBytes)
            records[i] = DirRecord(name: "", entry: r.entry, parent: -1) // 메모리 해제
        }
        return nodes[0]!
    }
}
