import Foundation

/// 스캔 시작 가능 여부 판단 (순수 함수, UI 의존 없음).
/// 스캔 중이거나, 정리 시트가 열려 있거나, 정리 실행 중이거나, 권한 온보딩이 끝나지 않았으면 시작할 수 없다.
public enum ScanGate {
    public static func canStartScan(isBusy: Bool, hasCleanupFlow: Bool,
                                    isExecutingCleanup: Bool, canProceed: Bool) -> Bool {
        !isBusy && !hasCleanupFlow && !isExecutingCleanup && canProceed
    }
}
