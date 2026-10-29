import Foundation

/// PLAN §16.1. 구버전 JSON의 "never"는 discouraged(정리 비권장)로 읽는다.
public enum Safety: String, Sendable, Equatable, Codable {
    case safe, review, discouraged

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "never" { self = .discouraged; return }
        guard let v = Safety(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "알 수 없는 safety: \(raw)"))
        }
        self = v
    }

    /// 엄격도 (클수록 엄격).
    var strictness: Int { switch self { case .safe: 0; case .review: 1; case .discouraged: 2 } }
}
public enum CleanupMethod: String, Sendable, Equatable, Codable { case trash, command, icloudEvict, none }

public struct CatalogCommand: Sendable, Equatable, Codable {
    public var tool: String
    public var args: [String]
    public init(tool: String, args: [String] = []) { self.tool = tool; self.args = args }
}

/// 카테고리 카탈로그 항목 (PLAN §6.1). JSON 키는 필드명과 동일. `excludePatterns`/`args`/`note`는 생략 가능.
public struct CatalogEntry: Sendable, Equatable, Codable {
    public var id: String
    public var title: String
    public var pathPatterns: [String]
    public var excludePatterns: [String]
    public var minAgeDays: Int?
    public var safety: Safety
    public var method: CleanupMethod
    public var command: CatalogCommand?
    public var regenerates: Bool
    public var note: String

    public init(id: String, title: String, pathPatterns: [String], excludePatterns: [String] = [],
                minAgeDays: Int? = nil, safety: Safety, method: CleanupMethod,
                command: CatalogCommand? = nil, regenerates: Bool = false, note: String = "") {
        self.id = id; self.title = title; self.pathPatterns = pathPatterns
        self.excludePatterns = excludePatterns; self.minAgeDays = minAgeDays
        self.safety = safety; self.method = method; self.command = command
        self.regenerates = regenerates; self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, pathPatterns, excludePatterns, minAgeDays, safety, method, command, regenerates, note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pathPatterns = try c.decodeIfPresent([String].self, forKey: .pathPatterns) ?? []
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays)
        safety = try c.decode(Safety.self, forKey: .safety)
        method = try c.decode(CleanupMethod.self, forKey: .method)
        command = try c.decodeIfPresent(CatalogCommand.self, forKey: .command)
        regenerates = try c.decodeIfPresent(Bool.self, forKey: .regenerates) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}
