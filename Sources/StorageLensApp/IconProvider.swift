import SwiftUI
import AppKit
import StorageCore

/// 로딩 완료를 뷰에 알리는 관찰 가능 상태. image(for:) 가 body 안에서 `revision` 을 읽어 갱신을 구독한다.
@MainActor
@Observable
private final class IconStore {
    static let shared = IconStore()
    private(set) var revision = 0
    private var flushScheduled = false

    /// 짧은 간격으로 모아서 한 번만 갱신 (아이콘 수십 개가 연달아 도착해도 재그리기 1회).
    func bump() {
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            self.flushScheduled = false
            self.revision &+= 1
        }
    }
}

private struct SendableImage: @unchecked Sendable { let image: NSImage }

/// 아이콘 조회 (perf-6). 뷰는 동기 API 를 그대로 쓴다: 캐시에 없으면 기본 심볼을 즉시 돌려주고
/// 백그라운드에서 로딩한 뒤 뷰를 다시 그린다. 조회 실패는 음성 캐시, 저장은 최대 64px 로 축소, 상한 512개.
@MainActor
enum IconProvider {
    nonisolated static let maxPixels = 64
    private static let cache = LookupCache<NSImage>(capacity: 512)
    private static var inFlight = Set<String>()

    static func image(for attribution: Attribution, isDirectory: Bool) -> Image {
        image(for: attribution.iconSource, isDirectory: isDirectory)
    }

    static func image(for source: IconSource, isDirectory: Bool) -> Image {
        _ = IconStore.shared.revision   // 로딩 완료 시 재평가되도록 구독
        switch source {
        case .appBundle(let path):
            if let img = lookup("app:" + path, load: { loadFile(path) }) { return Image(nsImage: img) }
        case .bundleID(let id):
            if let img = lookup("id:" + id, load: { loadBundle(id) }) { return Image(nsImage: img) }
        case .symbol(let name):
            return Image(systemName: name)
        case .none:
            break
        }
        return Image(systemName: isDirectory ? "folder.fill" : "doc.fill")
    }

    /// 캐시 적중이면 이미지, 음성 캐시면 nil, 미조회면 백그라운드 로딩을 시작하고 nil.
    private static func lookup(_ key: String, load: @escaping @Sendable () -> NSImage?) -> NSImage? {
        if let e = cache.peek(key) {
            if case .hit(let img) = e { return img }
            return nil
        }
        guard inFlight.insert(key).inserted else { return nil }
        Task.detached(priority: .utility) {
            let loaded = load().map { SendableImage(image: downscaled($0)) }
            await MainActor.run {
                cache.store(key, loaded?.image)
                inFlight.remove(key)
                IconStore.shared.bump()
            }
        }
        return nil
    }

    private nonisolated static func loadFile(_ path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    private nonisolated static func loadBundle(_ id: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// 최대 64x64 픽셀 비트맵으로 축소해 메모리를 줄인다.
    private nonisolated static func downscaled(_ src: NSImage) -> NSImage {
        let px = maxPixels
        var rect = CGRect(x: 0, y: 0, width: px, height: px)
        guard let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return src }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        guard let out = ctx.makeImage() else { return src }
        return NSImage(cgImage: out, size: NSSize(width: px, height: px))
    }
}
