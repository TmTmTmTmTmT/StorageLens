import Foundation

/// 프로세스가 연 파일 한 건 (PLAN §7).
public struct OpenFileRecord: Sendable, Equatable, Hashable, Codable {
    public var pid: Int32
    public var processName: String
    public var path: String
    public init(pid: Int32, processName: String, path: String) {
        self.pid = pid; self.processName = processName; self.path = path
    }
}

public protocol ProcessLister: Sendable {
    /// 열린 vnode 파일 목록. 권한 없는 pid는 건너뜀.
    func openFiles() -> [OpenFileRecord]
}

/// libproc 기반 시스템 구현 (PLAN §7). 권한 없는 pid는 건너뜀.
public struct SystemProcessLister: ProcessLister {
    public init() {}

    public func openFiles() -> [OpenFileRecord] {
        // pid 목록: 크기 조회 후 증가 대비 여유를 두고 재시도
        var pids: [pid_t] = []
        var capacity = 0
        let need = proc_listallpids(nil, 0)
        if need <= 0 { return [] }
        capacity = Int(need) / MemoryLayout<pid_t>.size + 256
        while true {
            pids = [pid_t](repeating: 0, count: capacity)
            let bytes = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            if bytes <= 0 { return [] }
            let n = Int(bytes) / MemoryLayout<pid_t>.size
            if n < capacity { pids.removeLast(capacity - n); break }
            capacity *= 2
        }

        var result: [OpenFileRecord] = []
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if size <= 0 { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / fdSize + 16)
            let got = fds.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if got <= 0 { continue }
            let count = Int(got) / fdSize

            var nameBuf = [CChar](repeating: 0, count: 1024)
            let nl = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = nl > 0 ? String(decoding: nameBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : "pid \(pid)"

            for i in 0..<count where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO,
                                       &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
                if r <= 0 { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if path.isEmpty { continue }
                result.append(OpenFileRecord(pid: pid, processName: name, path: path))
            }
        }
        return result
    }
}
