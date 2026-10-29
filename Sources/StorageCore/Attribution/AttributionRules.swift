import Foundation

/// `Resources/attribution-rules.json` 내용 (PLAN §5.2 규칙 1, 4, 7의 데이터).
public struct AttributionRules: Sendable, Codable, Equatable {
    public struct PathRule: Sendable, Codable, Equatable {
        /// `~` 로 시작하는 경로. 이 경로 자체와 하위 전체에 적용(가장 긴 패턴 우선).
        public var path: String
        public var appName: String
        public var bundleID: String?
        /// SF Symbol 이름 (bundleID가 없을 때 아이콘).
        public var symbol: String?
        /// CLI 도구 이름 — 설치 여부를 부제에 표시.
        public var tool: String?
        public var subtitle: String?
        public init(path: String, appName: String, bundleID: String? = nil, symbol: String? = nil,
                    tool: String? = nil, subtitle: String? = nil) {
            self.path = path; self.appName = appName; self.bundleID = bundleID
            self.symbol = symbol; self.tool = tool; self.subtitle = subtitle
        }
    }

    public var pathRules: [PathRule]
    /// 제조사 토큰(소문자) -> 표기 이름
    public var vendorNames: [String: String]
    /// Apple 데몬 사전. 키가 `*`로 끝나면 접두 일치.
    public var appleDaemons: [String: String]

    public init(pathRules: [PathRule] = [], vendorNames: [String: String] = [:], appleDaemons: [String: String] = [:]) {
        self.pathRules = pathRules; self.vendorNames = vendorNames; self.appleDaemons = appleDaemons
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(AttributionRules.self, from: data)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// 정확 일치 -> 세그먼트 절단(3개까지) -> `*` 접두 순.
    func daemonDescription(for id: String) -> String? {
        let lower = id.lowercased()
        var table: [String: String] = [:]
        var prefixes: [(String, String)] = []
        for (k, v) in appleDaemons {
            if k.hasSuffix("*") { prefixes.append((String(k.dropLast()).lowercased(), v)) }
            else { table[k.lowercased()] = v }
        }
        var parts = lower.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if let v = table[parts.joined(separator: ".")] { return v }
            parts.removeLast()
        }
        for (p, v) in prefixes.sorted(by: { $0.0.count > $1.0.count }) where lower.hasPrefix(p) { return v }
        return nil
    }
}
