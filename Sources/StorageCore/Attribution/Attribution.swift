import Foundation

public enum Confidence: String, Sendable, Equatable, Codable {
    case exact, inferred, unknown
}

/// 아이콘을 찾을 위치.
public enum IconSource: Sendable, Equatable, Codable {
    /// .app 번들 경로의 아이콘
    case appBundle(path: String)
    /// 알려진 번들 ID (NSWorkspace로 조회)
    case bundleID(String)
    /// SF Symbol 이름
    case symbol(String)
    case none
}

/// 프로그램 귀속 결과 (PLAN §5).
public struct Attribution: Sendable, Equatable, Codable {
    public var appName: String
    public var subtitle: String?
    public var bundleID: String?
    public var iconSource: IconSource
    public var confidence: Confidence
    /// 어느 규칙으로 귀속했는지 한 줄 설명 (상세 패널 표시용).
    public var rule: String
    public var isOrphanSuspect: Bool

    public init(appName: String, subtitle: String? = nil, bundleID: String? = nil,
                iconSource: IconSource = .none, confidence: Confidence, rule: String,
                isOrphanSuspect: Bool = false) {
        self.appName = appName; self.subtitle = subtitle; self.bundleID = bundleID
        self.iconSource = iconSource; self.confidence = confidence; self.rule = rule
        self.isOrphanSuspect = isOrphanSuspect
    }

    public static let unknown = Attribution(appName: "알 수 없음", confidence: .unknown, rule: "일치하는 규칙 없음")
}
