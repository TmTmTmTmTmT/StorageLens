import Foundation
@testable import StorageCore

/// 테스트 공용 헬퍼 (리소스 경로 해석, 고정 시계, 임시 경로).
struct FixedClock: StorageCore.Clock {
    var now: Date
}

enum TestSupport {
    /// 저장소 루트의 Resources 디렉터리 (이 파일 기준: Tests/StorageCoreTests/TestSupport.swift).
    static let resourcesDirectory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")

    static func resourceURL(_ name: String) -> URL {
        resourcesDirectory.appendingPathComponent(name)
    }

    static var catalogURL: URL { resourceURL("catalog.json") }
    static var attributionRulesURL: URL { resourceURL("attribution-rules.json") }

    static func loadCatalog() throws -> Catalog {
        try Catalog.load(from: Data(contentsOf: catalogURL))
    }

    /// 아직 생성되지 않은 고유 임시 경로 (`<tmp>/<prefix>-<UUID>`).
    static func uniqueTempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }
}
