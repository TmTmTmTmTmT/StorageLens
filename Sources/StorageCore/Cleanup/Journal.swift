import Foundation

/// 저널 한 줄 (PLAN §8.2). `method`는 CleanupMethod.rawValue 또는 "undo".
public struct JournalEntry: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var originalPath: String
    public var trashPath: String?
    /// trash: plan 크기. command/icloudEvict: 확보된 크기. undo: 되돌린 항목 크기.
    public var sizeBytes: Int64
    public var method: String
    /// "success" | "partial" | "failed" | "skipped"
    public var result: String
    public var detail: String?
    /// trash 성공 기록: 휴지통 항목의 (dev, inode, 논리 크기). 구기록에는 없음(되돌리기 불가).
    public var trashDev: Int32?
    public var trashInode: UInt64?
    public var trashSize: Int64?

    public init(timestamp: Date, originalPath: String, trashPath: String?, sizeBytes: Int64,
                method: String, result: String, detail: String? = nil,
                trashDev: Int32? = nil, trashInode: UInt64? = nil, trashSize: Int64? = nil) {
        self.timestamp = timestamp; self.originalPath = originalPath; self.trashPath = trashPath
        self.sizeBytes = sizeBytes; self.method = method; self.result = result; self.detail = detail
        self.trashDev = trashDev; self.trashInode = trashInode; self.trashSize = trashSize
    }
}

/// `Journal.read()` 결과: 정상 항목과 건너뛴 손상 줄 수.
public struct JournalReadResult: Sendable, Equatable {
    public let entries: [JournalEntry]
    public let corruptLineCount: Int
}

public struct JournalIOError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// 경로별 프로세스 전역 락 (인스턴스를 여러 개 만들어도 같은 파일은 같은 락을 쓴다).
private enum JournalLocks {
    private static let guardLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: NSLock] = [:]
    static func lock(for path: String) -> NSLock {
        guardLock.lock(); defer { guardLock.unlock() }
        if let l = locks[path] { return l }
        let l = NSLock(); locks[path] = l; return l
    }
}

/// append-only JSON Lines 저널. 위치는 주입.
/// 프로세스 안에서는 경로별 공유 락, 프로세스 사이에서는 `flock`으로 직렬화한다.
public final class Journal: Sendable {
    public let fileURL: URL
    private let lock: NSLock
    /// 이 크기를 넘으면 다음 append 직전에 회전한다 (PLAN §8.2 v1.2).
    public static let defaultMaxBytes: Int64 = 2 * 1024 * 1024
    public let maxBytes: Int64

    /// 회전된 이전 세대 파일 (`journal.1.jsonl`).
    public var rotatedURL: URL {
        let base = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(base).1.\(fileURL.pathExtension)")
    }

    public init(fileURL: URL, maxBytes: Int64 = Journal.defaultMaxBytes) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.lock = JournalLocks.lock(for: fileURL.standardizedFileURL.path)
    }

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var sharedInstances: [String: Journal] = [:]
    /// 경로별 프로세스 전역 공유 인스턴스.
    public static func shared(fileURL: URL) -> Journal {
        let key = fileURL.standardizedFileURL.path
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let j = sharedInstances[key] { return j }
        let j = Journal(fileURL: fileURL); sharedInstances[key] = j; return j
    }

    /// `~/Library/Application Support/StorageLens/journal.jsonl`
    public static func defaultURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/StorageLens/journal.jsonl")
    }

    private static func posixError(_ what: String) -> JournalIOError {
        JournalIOError(message: "\(what): \(String(cString: strerror(errno)))")
    }

    public func append(_ entry: JournalEntry) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var line = try enc.encode(entry)
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 잠금 획득 후 경로의 파일이 열어 둔 파일과 같은지 확인한다 (다른 프로세스가 회전했으면 다시 연다).
        var fd: Int32 = -1
        var st = stat()
        var attempts = 0
        while true {
            attempts += 1
            fd = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw Self.posixError("저널 열기 실패") }
            guard flock(fd, LOCK_EX) == 0 else { close(fd); throw Self.posixError("저널 잠금 실패") }
            guard fstat(fd, &st) == 0 else { flock(fd, LOCK_UN); close(fd); throw Self.posixError("저널 확인 실패") }
            var pst = stat()
            let same = stat(fileURL.path, &pst) == 0 && pst.st_ino == st.st_ino && pst.st_dev == st.st_dev
            if !same && attempts < 8 { flock(fd, LOCK_UN); close(fd); continue }
            if st.st_size > maxBytes && same {
                // 회전: 잠금을 쥔 채 기존 .1을 대체하며 이름을 바꾸고, 새 파일을 열어 잠근다.
                guard rename(fileURL.path, rotatedURL.path) == 0 else {
                    let e = Self.posixError("저널 회전 실패"); flock(fd, LOCK_UN); close(fd); throw e
                }
                flock(fd, LOCK_UN); close(fd)
                continue
            }
            break
        }
        defer { close(fd) }
        defer { flock(fd, LOCK_UN) }

        // 마지막 바이트가 개행이 아니면(이전 쓰기가 중간에 끊김) 개행을 먼저 붙여 줄을 분리한다.
        var payload = Data()
        if st.st_size > 0 {
            let rfd = open(fileURL.path, O_RDONLY | O_CLOEXEC)
            if rfd >= 0 {
                var last: UInt8 = 0
                let n = pread(rfd, &last, 1, st.st_size - 1)
                close(rfd)
                if n == 1, last != 0x0A { payload.append(0x0A) }
            }
        }
        payload.append(line)
        // 한 줄(+보정 개행)을 O_APPEND 단일 write로.
        let written = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == payload.count else { throw Self.posixError("저널 쓰기 실패") }
        _ = fsync(fd)
    }

    /// 정상 항목과 손상 줄 수. 회전된 `.1`(더 오래됨) + 현재 파일 합본, 오래된 순.
    public func read() -> JournalReadResult {
        lock.lock(); defer { lock.unlock() }
        let old = Self.readFile(rotatedURL)
        let cur = Self.readFile(fileURL)
        return JournalReadResult(entries: old.0 + cur.0, corruptLineCount: old.1 + cur.1)
    }

    private static func readFile(_ url: URL) -> ([JournalEntry], Int) {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return ([], 0) }
        defer { close(fd) }
        _ = flock(fd, LOCK_SH)
        defer { flock(fd, LOCK_UN) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var out: [JournalEntry] = []
        var corrupt = 0
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let e = try? dec.decode(JournalEntry.self, from: Data(raw)) { out.append(e) } else { corrupt += 1 }
        }
        return (out, corrupt)
    }

    /// 오래된 순. 손상된 줄은 건너뜀 (건너뛴 수는 `read()`).
    public func entries() -> [JournalEntry] { read().entries }
}
