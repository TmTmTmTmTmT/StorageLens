import Testing
@testable import StorageCore

@Suite struct ScanGateTests {
    private func gate(busy: Bool = false, flow: Bool = false, executing: Bool = false, proceed: Bool = true) -> Bool {
        ScanGate.canStartScan(isBusy: busy, hasCleanupFlow: flow, isExecutingCleanup: executing, canProceed: proceed)
    }

    @Test func idleAllowsScan() { #expect(gate()) }
    @Test func busyBlocks() { #expect(!gate(busy: true)) }
    @Test func openCleanupSheetBlocks() { #expect(!gate(flow: true)) }
    @Test func executingCleanupBlocks() { #expect(!gate(flow: true, executing: true)); #expect(!gate(executing: true)) }
    @Test func onboardingPendingBlocks() { #expect(!gate(proceed: false)) }
}
