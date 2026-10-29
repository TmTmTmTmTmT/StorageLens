import Foundation

/// 경로 -> 사용 중 프로세스 질의 (PLAN §7). 본 구현은 M1-T4.
public protocol InUseQuery: Sendable {
    /// `path` 자체 또는 그 하위에 열린 파일이 있는 프로세스 이름들(중복 제거, 정렬).
    func processes(usingPathPrefix path: String) -> [String]
}
