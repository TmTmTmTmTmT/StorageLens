import Foundation
import os

private let datalessLog = Logger(subsystem: "com.kimmingyu.StorageLens", category: "dataless")

/// 스캔·xattr 읽기가 iCloud dataless 파일을 내려받지 않도록 프로세스 단위 정책 설정 (PLAN §2).
/// 앱 시작 시 가장 먼저 호출. 성공 여부 반환.
@discardableResult
public func disableDatalessMaterialization() -> Bool {
    let rc = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                            IOPOL_SCOPE_PROCESS,
                            IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    if rc != 0 {
        let e = errno
        datalessLog.error("setiopolicy_np failed: errno=\(e, privacy: .public)")
        return false
    }
    return true
}
