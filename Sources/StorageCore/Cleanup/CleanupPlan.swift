import Foundation

/// 정리 선택 단위: 실제 경로(+선택적 카탈로그 매치) 또는 경로 없는 가상 항목(command 전용).
public struct CleanupSelection: Sendable {
    public let path: String?
    public let match: CatalogMatch?

    /// 경로 항목. `match`가 nil이면 카탈로그에 없는 직접 선택(review 취급, trash).
    public init(path: String, match: CatalogMatch? = nil) {
        self.path = path; self.match = match
    }

    /// 가상 항목 (예: xcode-sim-unavailable). command 전용.
    public init(virtual match: CatalogMatch) {
        self.path = nil; self.match = match
    }

    public var isVirtual: Bool { path == nil }
}

/// 정리 계획 항목. `Cleaner.plan()`만 생성한다 (internal init).
public struct CleanupPlanItem: Sendable, Equatable {
    public let path: String
    public let sizeBytes: Int64
    public let method: CleanupMethod
    public let inode: UInt64
    public let devID: Int32
    public let warnings: [String]
    /// 카탈로그 항목 id (직접 선택이면 nil).
    public let entryID: String?
    public let title: String?
    /// command 방식: plan 시점에 확인한 실행 파일 절대 경로와 인자.
    public let toolName: String?
    public let toolPath: String?
    public let commandArguments: [String]
    /// 경로 없는 가상 항목 (inode 재검증 대상 아님).
    public let isVirtual: Bool
    /// 정리 비권장 항목 (PLAN §16.2). execute에서 `acknowledgedDiscouraged`가 true일 때만 실행.
    public let isDiscouraged: Bool
    /// 크기 측정 중 읽지 못해 크기에 포함되지 않은 항목 수 (safety-13).
    public var unmeasuredCount: Int = 0

    init(path: String, sizeBytes: Int64, method: CleanupMethod, inode: UInt64, devID: Int32,
         warnings: [String] = [], entryID: String? = nil, title: String? = nil,
         toolName: String? = nil, toolPath: String? = nil, commandArguments: [String] = [],
         isVirtual: Bool = false, isDiscouraged: Bool = false, unmeasuredCount: Int = 0) {
        self.path = path; self.sizeBytes = sizeBytes; self.method = method
        self.inode = inode; self.devID = devID; self.warnings = warnings
        self.entryID = entryID; self.title = title
        self.toolName = toolName; self.toolPath = toolPath; self.commandArguments = commandArguments
        self.isVirtual = isVirtual
        self.isDiscouraged = isDiscouraged
        self.unmeasuredCount = unmeasuredCount
    }
}

/// plan 단계에서 거부된 선택.
public struct CleanupRejection: Sendable, Equatable {
    public let path: String
    public let reason: String
}

/// `plan()`만 생성할 수 있는 정리 계획. 외부 모듈에서 init 불가 (internal init) -> plan 없이 execute 불가는 컴파일 수준 보장.
/// 생성 후 10분이 지나면 만료.
public struct CleanupPlan: Sendable, Equatable {
    public let createdAt: Date
    public let items: [CleanupPlanItem]
    public let rejected: [CleanupRejection]

    init(createdAt: Date, items: [CleanupPlanItem], rejected: [CleanupRejection] = []) {
        self.createdAt = createdAt; self.items = items; self.rejected = rejected
    }

    public static let validityInterval: TimeInterval = 600

    /// 계획 전체에서 크기에 포함되지 않은 항목 수 합계.
    public var unmeasuredCount: Int { items.reduce(0) { $0 + $1.unmeasuredCount } }

    public func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= Self.validityInterval
    }
}

public enum CleanupStatus: String, Sendable, Equatable, Codable {
    case succeeded, partial, skipped, failed
}

/// iCloud evict 등에서 개별 파일 실패.
public struct CleanupFailure: Sendable, Equatable {
    public let path: String
    public let reason: String
}

public struct CleanupItemOutcome: Sendable, Equatable {
    public let path: String
    public let method: CleanupMethod
    public let status: CleanupStatus
    public let reason: String?
    /// trash 방식: 휴지통 내 결과 경로.
    public let trashedPath: String?
    /// plan 시점 크기.
    public let sizeBytes: Int64
    /// command/icloudEvict: 실행 후 측정한 크기. trash는 nil.
    public let sizeAfterBytes: Int64?
    /// 실제 확보된 바이트 (trash는 휴지통을 비울 때까지 0, command/evict는 전후 차이).
    public let freedBytes: Int64
    /// 실패 목록 (최대 `Cleaner.maxListedFailures`건; 초과분은 `omittedFailureCount`).
    public let failures: [CleanupFailure]
    public let journalError: String?
    /// icloudEvict: 업로드가 끝나지 않아(또는 확인 불가) 내리지 않고 건너뛴 파일 (최대 100건).
    public var skippedFiles: [CleanupFailure] = []
    /// 목록에서 잘려 나간 실패/건너뜀 수 ("외 N건").
    public var omittedFailureCount: Int = 0
    public var omittedSkippedCount: Int = 0
    /// 업로드 미완료로 건너뛴 전체 파일 수 (목록 상한과 무관).
    public var notUploadedCount: Int = 0
    /// 측정 중 읽지 못해 크기에서 빠진 항목 수.
    public var unmeasuredCount: Int = 0
}

public struct CleanupResult: Sendable, Equatable {
    public let planExpired: Bool
    public let outcomes: [CleanupItemOutcome]

    public var succeededCount: Int { outcomes.filter { $0.status == .succeeded }.count }
    public var skippedCount: Int { outcomes.filter { $0.status == .skipped }.count }
}

public struct UndoResult: Sendable, Equatable {
    public let success: Bool
    public let reason: String?
    /// 되돌리기 결과를 저널에 기록하지 못했을 때의 오류.
    public var journalError: String? = nil
}
