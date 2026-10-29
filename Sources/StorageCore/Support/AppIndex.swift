import Foundation

/// 설치된 앱 한 개 (PLAN §5.1).
public struct InstalledApp: Sendable, Equatable, Codable {
    public var bundleID: String
    public var displayName: String
    /// 번들 ID의 2번째 세그먼트 (`com.adobe.Photoshop` -> `adobe`).
    public var vendorToken: String
    /// 제조사 표기 이름(규칙 7의 제조사 매칭에서 appName으로 사용). 모르면 nil.
    public var vendorName: String?
    public var path: String
    public var lastUsed: Date?

    public init(bundleID: String, displayName: String, vendorToken: String? = nil,
                vendorName: String? = nil, path: String = "", lastUsed: Date? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        let parts = bundleID.split(separator: ".")
        self.vendorToken = vendorToken ?? (parts.count >= 2 ? String(parts[1]).lowercased() : "")
        self.vendorName = vendorName
        self.path = path
        self.lastUsed = lastUsed
    }
}

/// 설치 앱 색인 (스캔 시작 시 1회 생성).
public protocol AppIndex: Sendable {
    var apps: [InstalledApp] { get }
    /// 고아 판정 제외용 "알려진 ID" (LaunchAgents/Daemons 파일명·Label, 실행 중 앱 번들 ID 포함).
    var knownIdentifiers: Set<String> { get }
    var runningBundleIDs: Set<String> { get }
}

public extension AppIndex {
    func app(bundleID: String) -> InstalledApp? {
        apps.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

/// 값 기반 구현. 시스템 색인 구축(NSMetadataQuery 등)은 M1-T2에서 이 타입을 채우는 팩토리로 추가.
public struct SystemAppIndex: AppIndex {
    public let apps: [InstalledApp]
    public let knownIdentifiers: Set<String>
    public let runningBundleIDs: Set<String>

    public init(apps: [InstalledApp] = [], knownIdentifiers: Set<String> = [], runningBundleIDs: Set<String> = []) {
        self.apps = apps
        self.knownIdentifiers = knownIdentifiers
        self.runningBundleIDs = runningBundleIDs
    }
}
