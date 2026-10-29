import Foundation

/// 볼륨 용량 (PLAN §3-2). 사용 / 사용 가능 / 정리 가능의 합 = 전체.
public struct VolumeInfo: Sendable, Equatable {
    public var total: Int64
    /// `volumeAvailableCapacity` (지금 바로 쓸 수 있는 공간)
    public var available: Int64
    /// `volumeAvailableCapacityForImportantUsage` (정리 가능 공간 포함)
    public var availableForImportantUsage: Int64

    public init(total: Int64, available: Int64, availableForImportantUsage: Int64) {
        self.total = total; self.available = available; self.availableForImportantUsage = availableForImportantUsage
    }

    /// 정리 가능 = important − available (음수면 0).
    public var purgeable: Int64 { max(0, availableForImportantUsage - available) }
    public var used: Int64 { max(0, total - available - purgeable) }

    public static func read(path: String = "/System/Volumes/Data") -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacity else { return nil }
        return VolumeInfo(total: Int64(total), available: Int64(avail),
                          availableForImportantUsage: v.volumeAvailableCapacityForImportantUsage ?? Int64(avail))
    }
}
