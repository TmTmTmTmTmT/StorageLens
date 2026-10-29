import Foundation

public enum FDAStatus: String, Sendable, Equatable, Codable {
    case granted, denied, undetermined
}

/// 전체 디스크 접근 검사 (PLAN §3-1).
public enum FullDiskAccess {
    private enum Probe { case ok, denied, missing, other }

    private static func probe(_ url: URL) -> Probe {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { close(fd); return .ok }
        switch errno {
        case EPERM, EACCES: return .denied
        case ENOENT: return .missing
        default: return .other
        }
    }

    /// `~/Library/Safari` -> (없으면) `~/Library/Mail` 순으로 디렉터리 열기 시도.
    public static func check(home: URL) -> FDAStatus {
        let lib = home.appendingPathComponent("Library")
        for name in ["Safari", "Mail"] {
            switch probe(lib.appendingPathComponent(name)) {
            case .ok: return .granted
            case .denied: return .denied
            case .missing: continue
            case .other: return .undetermined
            }
        }
        return .undetermined
    }
}
