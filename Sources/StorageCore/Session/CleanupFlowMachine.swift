import Foundation

/// 정리 시트 흐름의 단계 전이를 담는 순수 값 타입 상태 머신 (PLAN §17 cq-1). UI·Task 의존 없음.
///
/// 전이표 (허용되지 않은 이벤트는 거부되고 상태는 그대로):
/// - idle: begin -> planning
/// - planning: planFinished -> preview, cancelPlanning/close -> closed
/// - preview: confirm -> executing, replan -> planning, close -> closed
/// - executing: executionFinished -> done (닫기·replan·재시작 거부)
/// - done: close -> closed, replan -> planning (계획 만료로 끝났을 때만)
/// - closed: 종료 상태 (모든 이벤트 거부; 늦게 도착한 계획·실행 결과도 무시)
public struct CleanupFlowMachine: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, planning, preview, executing, done, closed }

    public enum Event: Sendable, Equatable {
        case begin
        case planFinished
        case cancelPlanning
        case confirm
        case executionFinished(planExpired: Bool)
        case replan
        case close
    }

    public private(set) var phase: Phase
    /// 마지막 실행이 계획 만료로 끝났는지 (done 단계에서 replan 허용 조건).
    public private(set) var planExpired = false

    public init(phase: Phase = .idle) { self.phase = phase }

    /// 이벤트를 적용한다. 허용되면 true, 금지 전이면 false (상태 불변).
    @discardableResult
    public mutating func send(_ event: Event) -> Bool {
        guard let next = Self.next(phase, event, planExpired: planExpired) else { return false }
        if case .executionFinished(let expired) = event { planExpired = expired }
        if next == .planning { planExpired = false }
        phase = next
        return true
    }

    public func canSend(_ event: Event) -> Bool { Self.next(phase, event, planExpired: planExpired) != nil }

    private static func next(_ p: Phase, _ e: Event, planExpired: Bool) -> Phase? {
        switch (p, e) {
        case (.idle, .begin): return .planning
        case (.planning, .planFinished): return .preview
        case (.planning, .cancelPlanning), (.planning, .close): return .closed
        case (.preview, .confirm): return .executing
        case (.preview, .replan): return .planning
        case (.preview, .close): return .closed
        case (.executing, .executionFinished): return .done
        case (.done, .close): return .closed
        case (.done, .replan): return planExpired ? .planning : nil
        default: return nil
        }
    }

    /// 계획·실행 중에는 시스템 기본 닫기(Esc 등)를 막는다.
    public var isDismissBlocked: Bool { phase == .planning || phase == .executing }
    public var isExecuting: Bool { phase == .executing }
    /// 닫기 이벤트를 받아들일 수 있는지 (실행 중에는 false).
    public var canClose: Bool { canSend(.close) }
}
