import Foundation
import CoreServices

/// 다운로드 출처 (PLAN §5.3). 스캔 중에는 호출 금지 — 상세 패널을 열 때만 지연 조회한다.
public struct DownloadOrigin: Sendable, Equatable {
    /// `com.apple.quarantine`의 agent 필드 (다운로드한 앱 이름, 예: "Safari").
    public var agentName: String?
    public var quarantineDate: Date?
    /// `kMDItemWhereFroms` (보통 [다운로드 URL, 참조 페이지]).
    public var whereFroms: [String]

    public init(agentName: String? = nil, quarantineDate: Date? = nil, whereFroms: [String] = []) {
        self.agentName = agentName; self.quarantineDate = quarantineDate; self.whereFroms = whereFroms
    }

    /// 둘 다 없으면 nil.
    public static func lookup(_ url: URL) -> DownloadOrigin? {
        var origin = DownloadOrigin()
        if let q = readXattr(url.path, "com.apple.quarantine"), let s = String(data: q, encoding: .utf8) {
            let p = parseQuarantine(s)
            origin.agentName = p.agent
            origin.quarantineDate = p.date
        }
        origin.whereFroms = readWhereFroms(url)
        if origin.agentName == nil && origin.quarantineDate == nil && origin.whereFroms.isEmpty { return nil }
        return origin
    }

    /// 형식: `flags;hex-unix-time;agent;uuid`
    static func parseQuarantine(_ s: String) -> (agent: String?, date: Date?) {
        let f = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        var agent: String?
        var date: Date?
        if f.count > 1, let t = UInt64(f[1], radix: 16) { date = Date(timeIntervalSince1970: TimeInterval(t)) }
        if f.count > 2, !f[2].isEmpty { agent = f[2] }
        return (agent, date)
    }

    static func parseWhereFroms(_ data: Data) -> [String] {
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let arr = obj as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    private static func readWhereFroms(_ url: URL) -> [String] {
        if let d = readXattr(url.path, "com.apple.metadata:kMDItemWhereFroms") {
            let r = parseWhereFroms(d)
            if !r.isEmpty { return r }
        }
        if let item = MDItemCreate(nil, url.path as CFString),
           let v = MDItemCopyAttribute(item, "kMDItemWhereFroms" as CFString) as? [String] {
            return v
        }
        return []
    }

    private static func readXattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        let got = getxattr(path, name, &buf, size, 0, XATTR_NOFOLLOW)
        guard got > 0 else { return nil }
        return Data(buf.prefix(got))
    }
}
