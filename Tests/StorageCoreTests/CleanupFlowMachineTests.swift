import Testing
@testable import StorageCore

@Suite struct CleanupFlowMachineTests {
    typealias M = CleanupFlowMachine

    private func machine(in phase: M.Phase, expired: Bool = false) -> M {
        var m = M()
        switch phase {
        case .idle: break
        case .planning: m.send(.begin)
        case .preview: m.send(.begin); m.send(.planFinished)
        case .executing: m.send(.begin); m.send(.planFinished); m.send(.confirm)
        case .done: m.send(.begin); m.send(.planFinished); m.send(.confirm); m.send(.executionFinished(planExpired: expired))
        case .closed: m.send(.begin); m.send(.close)
        }
        #expect(m.phase == phase)
        return m
    }

    @Test func happyPath() {
        var m = M()
        let ok1 = m.send(.begin)
        #expect(ok1 && m.phase == .planning)
        let ok2 = m.send(.planFinished)
        #expect(ok2 && m.phase == .preview)
        let ok3 = m.send(.confirm)
        #expect(ok3 && m.phase == .executing)
        let ok4 = m.send(.executionFinished(planExpired: false))
        #expect(ok4 && m.phase == .done)
        let ok5 = m.send(.close)
        #expect(ok5 && m.phase == .closed)
    }

    @Test func planningCancelCloses() {
        var m = machine(in: .planning)
        let ok6 = m.send(.cancelPlanning)
        #expect(ok6 && m.phase == .closed)
        var n = machine(in: .planning)
        let ok7 = n.send(.close)
        #expect(ok7 && n.phase == .closed)
    }

    @Test func lateResultsAfterCloseIgnored() {
        var m = machine(in: .closed)
        let r1 = m.send(.planFinished); #expect(!r1)
        let r2 = m.send(.executionFinished(planExpired: false)); #expect(!r2)
        #expect(m.phase == .closed)
    }

    @Test func previewReplanAndClose() {
        var m = machine(in: .preview)
        let ok8 = m.send(.replan)
        #expect(ok8 && m.phase == .planning)
        var n = machine(in: .preview)
        let ok9 = n.send(.close)
        #expect(ok9 && n.phase == .closed)
    }

    @Test func expiredExecutionAllowsReplanOnly() {
        var m = machine(in: .done, expired: true)
        #expect(m.planExpired)
        let ok10 = m.send(.replan)
        #expect(ok10 && m.phase == .planning && !m.planExpired)
        var n = machine(in: .done, expired: false)
        let r3 = n.send(.replan); #expect(!r3 && n.phase == .done)
    }

    @Test func executingRejectsCloseAndRestart() {
        var m = machine(in: .executing)
        #expect(m.isExecuting && m.isDismissBlocked && !m.canClose)
        for e: M.Event in [.close, .replan, .begin, .confirm, .cancelPlanning, .planFinished] {
            let r = m.send(e)
            #expect(!r)
            #expect(m.phase == .executing)
        }
    }

    @Test func dismissBlockedOnlyWhilePlanningOrExecuting() {
        #expect(machine(in: .planning).isDismissBlocked)
        #expect(!machine(in: .preview).isDismissBlocked)
        #expect(!machine(in: .done).isDismissBlocked)
        #expect(!machine(in: .idle).isDismissBlocked)
    }

    /// 모든 (단계, 이벤트) 쌍 중 허용 전이는 표와 정확히 일치한다.
    @Test func allowedTransitionsExactly() {
        let events: [M.Event] = [.begin, .planFinished, .cancelPlanning, .confirm,
                                 .executionFinished(planExpired: false), .replan, .close]
        let phases: [M.Phase] = [.idle, .planning, .preview, .executing, .done, .closed]
        var allowed: [String: M.Phase] = [
            "idle/begin": .planning,
            "planning/planFinished": .preview, "planning/cancelPlanning": .closed, "planning/close": .closed,
            "preview/confirm": .executing, "preview/replan": .planning, "preview/close": .closed,
            "executing/executionFinished": .done,
            "done/close": .closed,
        ]
        for p in phases {
            for e in events {
                var m = machine(in: p)
                let key = "\(p)/\(String(describing: e).split(separator: "(").first!)"
                let ok = m.send(e)
                if let want = allowed[key] {
                    #expect(ok && m.phase == want, "\(key)")
                    allowed[key] = nil
                } else {
                    #expect(!ok && m.phase == p, "\(key)")
                }
            }
        }
        #expect(allowed.isEmpty)
    }
}
