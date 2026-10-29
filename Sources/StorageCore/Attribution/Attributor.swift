import Foundation

/// 프로그램 귀속 (PLAN §5.2). 규칙 1~8을 문서 순서대로 적용하고 경로별로 메모이즈한다.
public final class Attributor: @unchecked Sendable {
    public typealias ContainerIDReader = @Sendable (URL) -> String?

    private let homePath: String
    private let appIndex: any AppIndex
    private let rules: AttributionRules
    private let clock: any Clock
    private let inUse: any InUseQuery
    private let fileSystem: any FileSystem
    private let toolLocator: ToolLocator
    private let containerIDReader: ContainerIDReader
    private let sortedRules: [(path: String, rule: AttributionRules.PathRule)]
    private let knownLower: [String]
    private let installedVendorPrefixes: Set<String>
    private let installedIDsLower: [String]

    /// 규칙 7용 사전 계산 (앱별 정규화 이름). init 시 1회.
    private let appNorms: [(app: InstalledApp, norm: String)]
    /// 제조사 토큰 -> 해당 앱 목록 (bundleID 사전순, 앱 순서 비의존).
    private let appsByVendor: [String: [InstalledApp]]
    /// 정규화한 제조사 이름·토큰 -> 제조사 토큰 (폴더 이름이 제조사명과 정확히 같은 경우 공용 그룹 판정용).
    private let vendorKeyToToken: [String: String]

    /// 캐시 값: 귀속 결과 + 상속 표현용 원 규칙·깊이.
    private struct Entry {
        var attr: Attribution
        var baseRule: String
        var depth: Int
        var originName: String
    }
    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    static let maxCacheEntries = 200_000

    /// 제조사 공용 그룹 키 접두.
    public static let vendorGroupPrefix = "vendor:"

    static let userFileFolders = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music"]
    /// 고아 추정 위치 (PLAN §5.2) — 이 폴더들의 직속 항목만.
    static let orphanParentFolders: Set<String> = [
        "Caches", "Application Support", "Containers", "Group Containers", "Preferences",
        "Logs", "HTTPStorages", "WebKit", "Saved Application State",
    ]
    /// 이름 기반 규칙(2~8)을 적용하는 위치.
    static let nameParentFolders: Set<String> = orphanParentFolders.union(["Application Scripts"])
    static let orphanMinAgeDays: Double = 30

    public init(home: URL,
                appIndex: any AppIndex,
                rules: AttributionRules,
                clock: any Clock = SystemClock(),
                inUse: any InUseQuery,
                fileSystem: any FileSystem = SystemFileSystem(),
                toolLocator: ToolLocator? = nil,
                containerIDReader: ContainerIDReader? = nil) {
        let h = home.standardizedFileURL.path
        self.homePath = h
        self.appIndex = appIndex
        self.rules = rules
        self.clock = clock
        self.inUse = inUse
        self.fileSystem = fileSystem
        self.toolLocator = toolLocator ?? ToolLocator(home: home)
        self.containerIDReader = containerIDReader ?? Attributor.readContainerID
        self.sortedRules = rules.pathRules.map { r in
            let p = r.path.hasPrefix("~") ? h + r.path.dropFirst() : r.path
            return (String(p), r)
        }.sorted { $0.path.count > $1.path.count }
        self.knownLower = appIndex.knownIdentifiers.map { $0.lowercased() }
        let installed = appIndex.apps.map { $0.bundleID.lowercased() }
        self.installedVendorPrefixes = Set(installed.compactMap { Attributor.vendorPrefix($0) })
        self.installedIDsLower = installed.filter { $0.filter { $0 == "." }.count >= 2 }
        self.appNorms = appIndex.apps.compactMap { a in
            let n = Attributor.normalize(a.displayName)
            return n.isEmpty ? nil : (a, n)
        }
        var byVendor: [String: [InstalledApp]] = [:]
        for a in appIndex.apps where !a.vendorToken.isEmpty { byVendor[a.vendorToken, default: []].append(a) }
        for k in byVendor.keys { byVendor[k]!.sort { $0.bundleID < $1.bundleID } }
        self.appsByVendor = byVendor
        var vk: [String: String] = [:]
        for (tok, apps) in byVendor {
            vk[Attributor.normalize(tok)] = tok
            if let n = apps.compactMap(\.vendorName).first { vk[Attributor.normalize(n)] = tok }
            if let n = rules.vendorNames[tok] { vk[Attributor.normalize(n)] = tok }
        }
        self.vendorKeyToToken = vk
    }

    /// Containers 메타데이터 plist의 `MCMMetadataIdentifier`.
    public static func readContainerID(_ folder: URL) -> String? {
        let plist = folder.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let id = obj["MCMMetadataIdentifier"] as? String, !id.isEmpty else { return nil }
        return id
    }

    public func attribute(_ url: URL) -> Attribution {
        attribute(path: url.standardizedFileURL.path)
    }

    // MARK: - 메모이즈

    private func attribute(path: String) -> Attribution {
        entry(path: path).attr
    }

    private func entry(path: String) -> Entry {
        lock.lock(); let hit = cache[path]; lock.unlock()
        if let hit { return hit }
        let result = compute(path)
        lock.lock()
        if cache.count >= Self.maxCacheEntries { cache.removeAll(keepingCapacity: true) }
        cache[path] = result
        lock.unlock()
        return result
    }

    private func compute(_ path: String) -> Entry {
        if let base = computeBase(path) {
            return Entry(attr: base, baseRule: base.rule, depth: 0, originName: (path as NSString).lastPathComponent)
        }
        // 상속: 가장 가까운 귀속된 상위 폴더 결과. 근거는 원 규칙 + 깊이로만 표현 (문자열 누적 금지).
        let parent = (path as NSString).deletingLastPathComponent
        let unknown = Entry(attr: .unknown, baseRule: Attribution.unknown.rule, depth: 0, originName: "")
        guard parent.hasPrefix(homePath + "/") else { return unknown }
        let pe = entry(path: parent)
        if pe.attr.confidence == .unknown { return unknown }
        var inherited = pe.attr
        let depth = pe.depth + 1
        inherited.rule = "상위 폴더 '\(pe.originName)'에서 상속(\(depth)단계) — \(pe.baseRule)"
        inherited.isOrphanSuspect = false
        return Entry(attr: inherited, baseRule: pe.baseRule, depth: depth, originName: pe.originName)
    }

    /// 상속 이전의 직접 규칙 결과. 상속 대상이면 nil.
    private func computeBase(_ path: String) -> Attribution? {
        guard path.hasPrefix(homePath + "/") else { return .unknown }
        let rel = path.dropFirst(homePath.count + 1).split(separator: "/").map(String.init)
        guard let name = rel.last else { return .unknown }

        // 규칙 1: 경로 규칙 표 (가장 긴 패턴 우선)
        if let (rp, rule) = sortedRules.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            return pathRuleAttribution(rule, matched: rp)
        }
        // 사용자 파일
        if let first = rel.first, Self.userFileFolders.contains(first) {
            return Attribution(appName: "사용자 파일", subtitle: first, iconSource: .symbol("person.crop.square"),
                               confidence: .exact, rule: "홈의 \(first) 하위")
        }
        // 규칙 2~8: ~/Library/<폴더> 직속 항목
        if rel.count == 3, rel[0] == "Library", Self.nameParentFolders.contains(rel[1]) {
            return resolveName(path: path, folder: rel[1], name: name)
        }
        // 상속
        return nil
    }

    // MARK: - 규칙 1

    private func pathRuleAttribution(_ r: AttributionRules.PathRule, matched: String) -> Attribution {
        var subtitle = r.subtitle
        if let tool = r.tool {
            let t = toolLocator.locate(tool) != nil ? "\(tool) 설치됨" : "\(tool) 미설치"
            subtitle = subtitle.map { "\($0) · \(t)" } ?? t
        }
        let icon: IconSource = r.bundleID.map { IconSource.bundleID($0) } ?? r.symbol.map { IconSource.symbol($0) } ?? .none
        return Attribution(appName: r.appName, subtitle: subtitle, bundleID: r.bundleID, iconSource: icon,
                           confidence: .exact, rule: "경로 규칙: \(r.path)")
    }

    // MARK: - 규칙 2~8

    private func resolveName(path: String, folder: String, name rawName: String) -> Attribution {
        var name = rawName
        for ext in [".plist", ".savedState"] where name.hasSuffix(ext) && name.count > ext.count {
            name = String(name.dropLast(ext.count)); break
        }
        var id = name
        var viaContainer = false
        // 규칙 2
        if folder == "Containers", let cid = containerIDReader(URL(fileURLWithPath: path)) {
            id = cid; viaContainer = true
        }
        // 규칙 3~5
        if let (a, kind) = tryIDRules(id) {
            var a = a
            if viaContainer { a.rule = "Containers 메타데이터 ID(\(id)) → \(a.rule)" }
            _ = kind
            return a
        }
        // 규칙 6
        let stripped = Self.stripGroupPrefix(name)
        if stripped != name, let (a, _) = tryIDRules(stripped) {
            var a = a
            a.confidence = .inferred
            a.rule = "Group Containers 접두 제거(\(stripped)) → \(a.rule)"
            return a
        }
        // 규칙 7
        if let a = nameMatch(name) { return a }
        // 규칙 8 (+ 고아 추정)
        if isOrphan(path: path, folder: folder, originalID: id, strippedID: stripped) {
            return Attribution(appName: name, subtitle: "삭제된 앱의 데이터로 추정", iconSource: .symbol("questionmark.folder"),
                               confidence: .inferred, rule: "고아 추정: 설치된 앱·알려진 ID와 일치하지 않는 역DNS 이름", isOrphanSuspect: true)
        }
        return .unknown
    }

    /// 규칙 3 -> 4 -> 5 (id 하나에 대해).
    private func tryIDRules(_ id: String) -> (Attribution, Int)? {
        // 3
        if let app = appIndex.app(bundleID: id) {
            return (appAttribution(app, rule: "번들 ID 정확 일치", confidence: .exact), 3)
        }
        // 4
        if id.lowercased().hasPrefix("com.apple.") {
            return (Attribution(appName: "macOS 시스템", subtitle: rules.daemonDescription(for: id),
                                iconSource: .symbol("gearshape"), confidence: .exact,
                                rule: "Apple 시스템 (com.apple.)"), 4)
        }
        // 5
        var parts = id.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while parts.count >= 3 {
            parts.removeLast()
            if parts.count < 3 { break }   // 세그먼트 2개 남으면 중단
            let cand = parts.joined(separator: ".")
            if let app = appIndex.app(bundleID: cand) {
                return (appAttribution(app, rule: "번들 ID 접두 절단 → \(cand)", confidence: .inferred), 5)
            }
        }
        return nil
    }

    private func appAttribution(_ app: InstalledApp, rule: String, confidence: Confidence, subtitle: String? = nil) -> Attribution {
        Attribution(appName: app.displayName, subtitle: subtitle, bundleID: app.bundleID,
                    iconSource: app.path.isEmpty ? .bundleID(app.bundleID) : .appBundle(path: app.path),
                    confidence: confidence, rule: rule)
    }

    /// 팀 ID(10자 대문자·숫자 + `.`)와 `group.` 접두를 순서 무관하게 각 최대 1회 제거 (PLAN §5.2-6).
    static func stripGroupPrefix(_ name: String) -> String {
        var s = name
        var removedTeam = false, removedGroup = false
        while !(removedTeam && removedGroup) {
            if !removedGroup, s.lowercased().hasPrefix("group.") {
                s = String(s.dropFirst(6)); removedGroup = true; continue
            }
            if !removedTeam {
                let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, parts[0].count == 10,
                   parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                    s = String(parts[1]); removedTeam = true; continue
                }
            }
            break
        }
        return s
    }

    // MARK: - 규칙 7

    /// 소문자화, 공백·`-`·`_` 제거, 끝의 숫자·버전(`2`, `v3`, `2024`, `1.2`) 제거.
    public static func normalize(_ s: String) -> String {
        let t = Array(s.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" })
        func isDigit(_ c: Character) -> Bool { c >= "0" && c <= "9" }
        // 끝에서부터 `v?[0-9]+(\.[0-9]+)*` 꼬리를 찾는다 (정규식 없이).
        var i = t.count
        guard i > 0, isDigit(t[i - 1]) else { return String(t) }
        var start = i
        while true {
            while i > 0, isDigit(t[i - 1]) { i -= 1 }
            start = i
            if i >= 2, t[i - 1] == ".", isDigit(t[i - 2]) { i -= 1; continue }
            break
        }
        if start > 0, t[start - 1] == "v" { start -= 1 }
        return start > 0 ? String(t[0..<start]) : String(t)
    }

    private func nameMatch(_ name: String) -> Attribution? {
        let nf = Self.normalize(name)
        guard !nf.isEmpty else { return nil }
        // 폴더 이름이 제조사 토큰·제조사명과 정확히 같고 그 제조사 앱이 2개 이상이면, 접두 매칭보다 먼저 공용 그룹.
        // 앱 표시 이름과 정확히 같은 폴더(예 "Google Chrome")는 기존대로 앱 귀속.
        if let tok = vendorKeyToToken[nf], let vapps = appsByVendor[tok], vapps.count >= 2,
           !appNorms.contains(where: { $0.norm == nf }) {
            return sharedVendorAttribution(token: tok, apps: vapps, folder: name, firstWord: name)
        }
        var best: InstalledApp?
        func consider(_ a: InstalledApp) {
            if best == nil || a.displayName.count > best!.displayName.count
                || (a.displayName.count == best!.displayName.count && a.bundleID < best!.bundleID) { best = a }
        }
        for (app, na) in appNorms {
            if nf == na { consider(app); continue }
            if (nf.hasPrefix(na) || na.hasPrefix(nf)) && min(nf.count, na.count) >= 5 { consider(app) }
        }
        if let app = best {
            return appAttribution(app, rule: "이름 매칭: '\(name)' ≈ '\(app.displayName)'", confidence: .inferred,
                                  subtitle: nil)
        }
        // 제조사 토큰 일치
        let firstWord = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        let fw = firstWord.lowercased()
        if fw.count >= 4, let vendorApps = appsByVendor[fw], let vendorApp = vendorApps.first {
            let vname = vendorApp.vendorName ?? rules.vendorNames[fw] ?? (fw.prefix(1).uppercased() + fw.dropFirst())
            if vendorApps.count >= 2 {
                return sharedVendorAttribution(token: fw, apps: vendorApps, folder: name, firstWord: firstWord)
            }
            let bid = vendorApp.bundleID
            return Attribution(appName: vname, subtitle: name, bundleID: bid,
                               iconSource: vendorApp.path.isEmpty ? .bundleID(bid) : .appBundle(path: vendorApp.path),
                               confidence: .inferred, rule: "이름 매칭: 첫 단어 '\(firstWord)' = 제조사 토큰")
        }
        return nil
    }

    /// 같은 제조사 앱이 여러 개: 특정 앱에 귀속하지 않고 제조사 공용 그룹 (safety-9).
    private func sharedVendorAttribution(token: String, apps: [InstalledApp], folder: String, firstWord: String) -> Attribution {
        let vname = apps.first?.vendorName ?? rules.vendorNames[token] ?? (token.prefix(1).uppercased() + token.dropFirst())
        return Attribution(appName: "\(vname) 공용", subtitle: folder, bundleID: Self.vendorGroupPrefix + token,
                           iconSource: .none, confidence: .inferred,
                           rule: "이름 매칭: 첫 단어 '\(firstWord)' = 제조사 토큰 (설치 앱 \(apps.count)개 → 제조사 공용)")
    }

    // MARK: - 고아 추정

    /// 역DNS 앞 2세그먼트(소문자). 세그먼트가 2개 미만이면 nil.
    private static func vendorPrefix(_ id: String) -> String? {
        let parts = id.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return parts[0] + "." + parts[1]
    }

    private func isOrphan(path: String, folder: String, originalID: String, strippedID: String) -> Bool {
        guard Self.orphanParentFolders.contains(folder) else { return false }
        // 역DNS 형태 (점 2개 이상)
        let dotted = originalID.filter { $0 == "." }.count >= 2
        guard dotted, !originalID.contains(where: { $0.isWhitespace }) else { return false }
        let lowerIDs = [originalID.lowercased(), strippedID.lowercased()]
        // com.apple 아님
        if lowerIDs.contains(where: { $0.hasPrefix("com.apple.") }) { return false }
        // 규칙 표에 없음
        if sortedRules.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { return false }
        // 알려진 ID 접두 일치 없음
        for id in lowerIDs {
            for k in knownLower where k == id || id.hasPrefix(k + ".") || k.hasPrefix(id + ".") { return false }
        }
        // 같은 제조사 접두(앞 2세그먼트)의 설치 앱이 있으면 고아 아님
        for id in lowerIDs {
            if let vp = Self.vendorPrefix(id), installedVendorPrefixes.contains(vp) { return false }
        }
        // 폴더 이름에 설치 앱 번들 ID가 포함되면 고아 아님
        let lowerName = ((path as NSString).lastPathComponent).lowercased()
        if installedIDsLower.contains(where: { lowerName.contains($0) }) { return false }
        // 수정일 30일 이상
        guard let attrs = try? fileSystem.attributes(at: URL(fileURLWithPath: path)),
              clock.now.timeIntervalSince(attrs.modified) >= Self.orphanMinAgeDays * 86400 else { return false }
        // 사용 중 아님
        if !inUse.processes(usingPathPrefix: path).isEmpty { return false }
        return true
    }
}
