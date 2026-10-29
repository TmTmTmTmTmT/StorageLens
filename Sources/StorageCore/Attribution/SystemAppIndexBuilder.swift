import Foundation
import CoreServices
import AppKit

private final class QueryResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _done = false
    private var _paths: [String] = []
    var done: Bool { lock.lock(); defer { lock.unlock() }; return _done }
    var paths: [String] { lock.lock(); defer { lock.unlock() }; return _paths }
    func finish(_ p: [String]) { lock.lock(); _paths = p; _done = true; lock.unlock() }
}

extension SystemAppIndex {
    /// 시스템 색인 구축 (PLAN §5.1). NSMetadataQuery를 `queryTimeout`초 안에 시도하고,
    /// 실패·0건이면 /Applications, /Applications/Utilities, ~/Applications, /System/Applications를 깊이 2로 직접 열거.
    public static func build(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                             queryTimeout: TimeInterval = 4,
                             useMetadataQuery: Bool = true,
                             vendorNames: [String: String] = [:]) -> SystemAppIndex {
        var paths: [String] = useMetadataQuery ? metadataQueryAppPaths(timeout: queryTimeout) : []
        if paths.isEmpty { paths = enumerateAppPaths(home: home) }
        var seen = Set<String>()
        let apps = paths.filter { seen.insert($0).inserted }
            .compactMap { makeApp(path: $0, vendorNames: vendorNames) }
        return SystemAppIndex(apps: apps,
                              knownIdentifiers: collectKnownIdentifiers(home: home),
                              runningBundleIDs: runningBundleIDs())
    }

    static func isUsableAppPath(_ p: String) -> Bool {
        guard p.hasSuffix(".app") else { return false }
        // 중첩 번들(헬퍼 앱 등)·시뮬레이터/빌드 산출물 제외
        if p.dropLast(4).contains(".app/") { return false }
        for bad in ["/CoreSimulator/", "/DerivedData/", "/.Trash/", ".xcarchive/", "/System/Volumes/", "/private/var/"] where p.contains(bad) {
            return false
        }
        return true
    }

    static func metadataQueryAppPaths(timeout: TimeInterval) -> [String] {
        let box = QueryResultBox()
        let sem = DispatchSemaphore(value: 0)
        let thread = Thread {
            let q = NSMetadataQuery()
            q.predicate = NSPredicate(format: "%K == %@", "kMDItemContentType", "com.apple.application-bundle")
            let obs = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: q, queue: nil) { _ in
                box.finish([])   // 플래그만 세움. 결과는 아래에서 수집
            }
            var finished = false
            if q.start() {
                let deadline = Date().addingTimeInterval(timeout)
                while !box.done && Date() < deadline {
                    if !RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1)) {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                }
                finished = box.done
                q.disableUpdates()
                var out: [String] = []
                if finished {
                    for i in 0..<q.resultCount {
                        if let item = q.result(at: i) as? NSMetadataItem,
                           let p = item.value(forAttribute: NSMetadataItemPathKey) as? String { out.append(p) }
                    }
                }
                q.stop()
                box.finish(out)
            } else {
                box.finish([])
            }
            NotificationCenter.default.removeObserver(obs)
            sem.signal()
        }
        thread.start()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return box.paths.filter(isUsableAppPath).sorted()
    }

    static func enumerateAppPaths(home: URL) -> [String] {
        let roots = ["/Applications", "/Applications/Utilities",
                     home.appendingPathComponent("Applications").path, "/System/Applications"]
        let fm = FileManager.default
        var out: [String] = []
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for n in names.sorted() {
                let p = root + "/" + n
                if n.hasSuffix(".app") { out.append(p); continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
                      let sub = try? fm.contentsOfDirectory(atPath: p) else { continue }
                for s in sub.sorted() where s.hasSuffix(".app") { out.append(p + "/" + s) }
            }
        }
        return out
    }

    static func makeApp(path: String, vendorNames: [String: String]) -> InstalledApp? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let bid = dict["CFBundleIdentifier"] as? String, !bid.isEmpty else { return nil }
        let fileName = (path as NSString).lastPathComponent
        let display = String(fileName.dropLast(4))
        let parts = bid.split(separator: ".")
        let token = parts.count >= 2 ? String(parts[1]).lowercased() : ""
        let vendor: String? = token.isEmpty ? nil : (vendorNames[token] ?? token.prefix(1).uppercased() + token.dropFirst())
        var last: Date?
        if let item = MDItemCreate(nil, path as CFString) {
            last = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
        }
        return InstalledApp(bundleID: bid, displayName: display, vendorToken: token,
                            vendorName: vendor, path: path, lastUsed: last)
    }

    static func collectKnownIdentifiers(home: URL) -> Set<String> {
        let dirs = ["/Library/LaunchAgents", "/Library/LaunchDaemons",
                    home.appendingPathComponent("Library/LaunchAgents").path]
        var ids = Set<String>()
        let fm = FileManager.default
        for d in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for n in names where n.hasSuffix(".plist") {
                ids.insert(String(n.dropLast(6)))
                if let data = fm.contents(atPath: d + "/" + n),
                   let obj = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                   let label = obj["Label"] as? String { ids.insert(label) }
            }
        }
        return ids
    }

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    }
}
