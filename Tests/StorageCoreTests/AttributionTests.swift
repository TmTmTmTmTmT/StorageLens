import Testing
import Foundation
@testable import StorageCore

private struct FakeInUse: InUseQuery {
    var busy: [String] = []
    func processes(usingPathPrefix path: String) -> [String] {
        busy.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) ? ["fake"] : []
    }
}

private let rulesURL = TestSupport.attributionRulesURL

private func loadRules() throws -> AttributionRules { try AttributionRules(contentsOf: rulesURL) }

private final class Env {
    let home: URL
    let now = Date()
    init() throws {
        let base = TestSupport.uniqueTempURL("attr")
        home = base.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

    @discardableResult
    func dir(_ rel: String, ageDays: Double = 100) throws -> URL {
        let u = home.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ageDays * 86400)], ofItemAtPath: u.path)
        return u
    }

    func attributor(apps: [InstalledApp] = [], known: Set<String> = [], rules: AttributionRules? = nil,
                    busy: [String] = [], tools: ToolLocator? = nil) throws -> Attributor {
        Attributor(home: home,
                   appIndex: SystemAppIndex(apps: apps, knownIdentifiers: known),
                   rules: try rules ?? loadRules(),
                   clock: FixedClock(now: now),
                   inUse: FakeInUse(busy: busy),
                   toolLocator: tools ?? ToolLocator(candidateDirectories: []))
    }
}

private let claude = InstalledApp(bundleID: "com.anthropic.claudefordesktop", displayName: "Claude",
                                  vendorName: "Anthropic", path: "/Applications/Claude.app")
private let photoshop = InstalledApp(bundleID: "com.adobe.Photoshop", displayName: "Adobe Photoshop 2025",
                                     vendorName: "Adobe", path: "/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app")

@Suite struct AttributionTests {
    // MARK: 필수 4사례
    @Test func huggingFace() throws {
        let e = try Env()
        let u = try e.dir(".cache/huggingface")
        let a = try e.attributor().attribute(u)
        #expect(a.appName == "Hugging Face 라이브러리")
        #expect(a.confidence == .exact)
        // 하위 경로도 규칙 1
        let sub = try e.dir(".cache/huggingface/hub/models--a--b")
        #expect(try e.attributor().attribute(sub).appName == "Hugging Face 라이브러리")
    }

    @Test func shipItPrefixTruncation() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/com.anthropic.claudefordesktop.ShipIt")
        let a = try e.attributor(apps: [claude]).attribute(u)
        #expect(a.appName == "Claude")
        #expect(a.confidence == .inferred)
        #expect(a.bundleID == "com.anthropic.claudefordesktop")
    }

    @Test func appleSystem() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/com.apple.nsurlsessiond")
        let a = try e.attributor().attribute(u)
        #expect(a.appName == "macOS 시스템")
        #expect(a.confidence == .exact)
        #expect(a.subtitle != nil)   // 데몬 사전
        let drag = try e.dir("Library/Caches/com.apple.SwiftUI.Drag-1234-ABCD")
        #expect(try e.attributor().attribute(drag).subtitle != nil)
        let plain = try e.dir("Library/Caches/com.apple.zzzunknown")
        let pa = try e.attributor().attribute(plain)
        #expect(pa.appName == "macOS 시스템" && pa.subtitle == nil && !pa.isOrphanSuspect)
    }

    @Test func adobeCameraRawVendorMatch() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/Adobe Camera Raw 2")
        let a = try e.attributor(apps: [photoshop]).attribute(u)
        #expect(a.appName == "Adobe")
        #expect(a.subtitle == "Adobe Camera Raw 2")
        #expect(a.confidence == .inferred)
    }

    // MARK: 규칙별
    @Test func rule1BeatsRule3() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/com.example.Thing")
        let app = InstalledApp(bundleID: "com.example.Thing", displayName: "Thing")
        let rules = AttributionRules(pathRules: [.init(path: "~/Library/Caches/com.example.Thing", appName: "Rule Winner")])
        let a = try e.attributor(apps: [app], rules: rules).attribute(u)
        #expect(a.appName == "Rule Winner")
    }

    @Test func rule1LongestPatternWins() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/Foo/Bar")
        let rules = AttributionRules(pathRules: [
            .init(path: "~/Library/Caches/Foo", appName: "Short"),
            .init(path: "~/Library/Caches/Foo/Bar", appName: "Long"),
        ])
        #expect(try e.attributor(rules: rules).attribute(u).appName == "Long")
    }

    @Test func rule1ToolSubtitle() throws {
        let e = try Env()
        let bin = try e.dir(".local/bin")
        let tool = bin.appendingPathComponent("uv")
        try "#!/bin/sh\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let u = try e.dir(".cache/uv")
        let with = try e.attributor(tools: ToolLocator(home: e.home)).attribute(u)
        #expect(with.appName == "uv")
        #expect(with.subtitle?.contains("설치됨") == true)
        let without = try e.attributor(tools: ToolLocator(candidateDirectories: [])).attribute(u)
        #expect(without.subtitle?.contains("미설치") == true)
    }

    @Test func rule1RealRulesCoverPlanExamples() throws {
        let e = try Env()
        let r = try loadRules()
        let a = try e.attributor(rules: r)
        for (rel, name) in [(".cache/uv", "uv"), ("Library/Caches/Homebrew", "Homebrew"),
                            ("Library/Caches/ms-playwright", "Playwright"),
                            ("Library/Developer/Xcode/DerivedData", "Xcode"),
                            ("Library/Mobile Documents", "iCloud Drive"), (".cache/codex-runtimes", "Codex")] {
            #expect(a.attribute(e.home.appendingPathComponent(rel)).appName == name, "\(rel)")
        }
        #expect(r.appleDaemons.count == 30)
    }

    @Test func rule2ContainerMetadata() throws {
        let e = try Env()
        let u = try e.dir("Library/Containers/WeirdFolderName")
        let plist: [String: Any] = ["MCMMetadataIdentifier": "com.anthropic.claudefordesktop"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: u.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let a = try e.attributor(apps: [claude]).attribute(u)
        #expect(a.appName == "Claude")
        #expect(a.confidence == .exact)
        // 읽기 실패 -> 폴더 이름 사용
        let u2 = try e.dir("Library/Containers/com.anthropic.claudefordesktop")
        #expect(try e.attributor(apps: [claude]).attribute(u2).appName == "Claude")
    }

    @Test func rule3Exact() throws {
        let e = try Env()
        let u = try e.dir("Library/Application Support/com.anthropic.claudefordesktop")
        let a = try e.attributor(apps: [claude]).attribute(u)
        #expect(a.confidence == .exact && a.appName == "Claude")
        #expect(a.iconSource == .appBundle(path: "/Applications/Claude.app"))
    }

    @Test func rule5StopsAtTwoSegments() throws {
        let e = try Env()
        let app = InstalledApp(bundleID: "com.foo", displayName: "Foo")
        let u = try e.dir("Library/Caches/com.foo.bar")   // 절단하면 세그먼트 2개 -> 중단
        let a = try e.attributor(apps: [app]).attribute(u)
        #expect(a.appName != "Foo")
    }

    @Test func rule6GroupContainers() throws {
        let e = try Env()
        let g1 = try e.dir("Library/Group Containers/group.com.anthropic.claudefordesktop")
        let g2 = try e.dir("Library/Group Containers/ABCDE12345.com.anthropic.claudefordesktop")
        let at = try e.attributor(apps: [claude])
        for g in [g1, g2] {
            let a = at.attribute(g)
            #expect(a.appName == "Claude" && a.confidence == .inferred)
        }
    }

    @Test func rule6TeamIDAndGroupPrefix() throws {
        #expect(Attributor.stripGroupPrefix("UBF8T346G9.group.com.microsoft.shared") == "com.microsoft.shared")
        #expect(Attributor.stripGroupPrefix("group.UBF8T346G9.com.foo.bar") == "com.foo.bar")
        #expect(Attributor.stripGroupPrefix("group.group.com.foo.bar") == "group.com.foo.bar")
        #expect(Attributor.stripGroupPrefix("group.com.foo.bar") == "com.foo.bar")
        #expect(Attributor.stripGroupPrefix("com.foo.bar") == "com.foo.bar")
        let e = try Env()
        let at = try e.attributor(apps: [claude])
        let g = try e.dir("Library/Group Containers/ABCDE12345.group.com.anthropic.claudefordesktop")
        let a = at.attribute(g)
        #expect(a.appName == "Claude" && a.confidence == .inferred)
        // Microsoft 계열: 설치 앱과 같은 제조사 접두 -> 고아 아님
        let word = InstalledApp(bundleID: "com.microsoft.Word", displayName: "Microsoft Word", vendorName: "Microsoft")
        let m = try e.dir("Library/Group Containers/UBF8T346G9.group.com.microsoft.shared")
        #expect(try e.attributor(apps: [word]).attribute(m).isOrphanSuspect == false)
    }

    @Test func rule7NameMatching() throws {
        let e = try Env()
        let apps = [InstalledApp(bundleID: "com.x.fcp", displayName: "Final Cut Pro"),
                    InstalledApp(bundleID: "com.x.fc", displayName: "Final Cut Pro Trial Edition")]
        // 정규화 일치 + 버전 제거
        let a = try e.attributor(apps: [apps[0]]).attribute(try e.dir("Library/Application Support/Final-Cut_Pro 2"))
        #expect(a.appName == "Final Cut Pro" && a.confidence == .inferred)
        // 접두 일치(짧은 쪽 >= 5): 후보 여럿이면 표시 이름이 가장 긴 것
        let b = try e.attributor(apps: apps).attribute(try e.dir("Library/Caches/FinalCutPro"))
        #expect(b.appName == "Final Cut Pro Trial Edition")   // 둘 다 후보 -> 가장 긴 표시 이름
        let c = try e.attributor(apps: apps).attribute(try e.dir("Library/Caches/FinalCutProTrialEditionData"))
        #expect(c.appName == "Final Cut Pro Trial Edition")
        // 짧은 쪽 < 5 는 접두 일치 불가
        let tiny = InstalledApp(bundleID: "com.t.abc", displayName: "Abcd")
        let d = try e.attributor(apps: [tiny]).attribute(try e.dir("Library/Caches/AbcdExtra"))
        #expect(d.confidence == .unknown)
    }

    @Test func rule7ShortVendorTokenNoMatch() throws {
        let e = try Env()
        let ibm = InstalledApp(bundleID: "com.ibm.Tool", displayName: "BlueTool", vendorName: "IBM")
        let a = try e.attributor(apps: [ibm]).attribute(try e.dir("Library/Caches/IBM Something"))
        #expect(a.confidence == .unknown)
    }

    @Test func noEditDistance() throws {
        let e = try Env()
        let a = try e.attributor(apps: [claude]).attribute(try e.dir("Library/Caches/Claud3x"))
        #expect(a.confidence == .unknown)
    }

    @Test func rule8Unknown() throws {
        let e = try Env()
        let a = try e.attributor().attribute(try e.dir("Library/Caches/Mystery"))
        #expect(a == .unknown)
    }

    @Test func normalizeRules() {
        #expect(Attributor.normalize("Adobe Camera Raw 2") == "adobecameraraw")
        #expect(Attributor.normalize("Foo-Bar_v3") == "foobar")
        #expect(Attributor.normalize("App-2024") == "app")
        #expect(Attributor.normalize("2024") == "2024")
    }

    // MARK: 상속·사용자 파일
    @Test func inheritance() throws {
        let e = try Env()
        let sub = try e.dir("Library/Application Support/com.anthropic.claudefordesktop/a/b")
        let a = try e.attributor(apps: [claude]).attribute(sub)
        #expect(a.appName == "Claude" && a.rule.contains("상속"))
        // 귀속 없는 경로
        let none = try e.dir("Library/Caches/Mystery/x")
        #expect(try e.attributor().attribute(none).confidence == .unknown)
    }

    @Test func userFiles() throws {
        let e = try Env()
        let u = try e.dir("Documents/Projects/x")
        let a = try e.attributor().attribute(u)
        #expect(a.appName == "사용자 파일")
        #expect(try e.attributor().attribute(try e.dir("Downloads")).appName == "사용자 파일")
    }

    @Test func outsideHomeUnknown() throws {
        let e = try Env()
        #expect(try e.attributor().attribute(URL(fileURLWithPath: "/usr/bin")) == .unknown)
    }

    // MARK: 고아 추정
    @Test func orphanPositive() throws {
        let e = try Env()
        let u = try e.dir("Library/Application Support/com.gone.OldApp", ageDays: 60)
        let a = try e.attributor().attribute(u)
        #expect(a.isOrphanSuspect && a.confidence == .inferred)
    }

    @Test func orphanNegatives() throws {
        let e = try Env()
        let at1 = try e.attributor()
        // 30일 미만
        #expect(!at1.attribute(try e.dir("Library/Caches/com.gone.Recent", ageDays: 5)).isOrphanSuspect)
        // 점 2개 미만
        #expect(!at1.attribute(try e.dir("Library/Caches/gone.thing", ageDays: 90)).isOrphanSuspect)
        // 지정 폴더 직속 아님 (하위)
        #expect(!at1.attribute(try e.dir("Library/Caches/com.gone.Parent/com.gone.Child", ageDays: 90)).isOrphanSuspect)
        // 지정 폴더 아님
        #expect(!at1.attribute(try e.dir("Library/Fonts/com.gone.Font", ageDays: 90)).isOrphanSuspect)
        // com.apple
        #expect(!at1.attribute(try e.dir("Library/Caches/com.apple.gone", ageDays: 90)).isOrphanSuspect)
        // 알려진 ID 접두
        let k = try e.dir("Library/Caches/com.known.Agent.helper", ageDays: 90)
        #expect(!(try e.attributor(known: ["com.known.Agent"]).attribute(k).isOrphanSuspect))
        // 규칙 표에 있음
        let r = try e.dir("Library/Caches/com.ruled.Thing", ageDays: 90)
        let rules = AttributionRules(pathRules: [.init(path: "~/Library/Caches/com.ruled.Thing", appName: "R")])
        #expect(!(try e.attributor(rules: rules).attribute(r).isOrphanSuspect))
        // 사용 중
        let busy = try e.dir("Library/Caches/com.gone.Busy", ageDays: 90)
        let b = try e.attributor(busy: [busy.appendingPathComponent("lock").path]).attribute(busy)
        #expect(!b.isOrphanSuspect)
        // 규칙 3/5/6 성공 -> 고아 아님
        let m = try e.dir("Library/Caches/com.anthropic.claudefordesktop.ShipIt", ageDays: 90)
        #expect(!(try e.attributor(apps: [claude]).attribute(m).isOrphanSuspect))
    }

    @Test func orphanFalsePositivesF1() throws {
        let e = try Env()
        // 같은 제조사 접두의 다른 번들 ID
        let matlab = InstalledApp(bundleID: "com.mathworks.matlab", displayName: "MATLAB")
        let m = try e.dir("Library/Caches/com.mathworks.matlabconnector", ageDays: 90)
        #expect(!(try e.attributor(apps: [matlab]).attribute(m).isOrphanSuspect))
        // 접미가 붙은 설치 앱 ID (제조사 접두 동일)
        let polaris = InstalledApp(bundleID: "com.infraware.polarisofficeService", displayName: "Polaris Service")
        let p = try e.dir("Library/Application Support/com.infraware.polarisoffice", ageDays: 90)
        #expect(!(try e.attributor(apps: [polaris]).attribute(p).isOrphanSuspect))
        // 이름에 설치 앱 번들 ID가 부분 문자열로 포함 (접두 제거본이 아닌 경로)
        let vivid = InstalledApp(bundleID: "com.goodsnooze.vivid", displayName: "Vivid")
        let v = try e.dir("Library/Caches/bugsnag-shared-com.goodsnooze.vivid", ageDays: 90)
        #expect(!(try e.attributor(apps: [vivid]).attribute(v).isOrphanSuspect))
        // 관련 없는 설치 앱만 있으면 여전히 고아
        let other = try e.dir("Library/Caches/com.gone.OldApp", ageDays: 90)
        #expect(try e.attributor(apps: [matlab]).attribute(other).isOrphanSuspect)
    }

    @Test func memoizationConsistentAcrossThreads() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/com.anthropic.claudefordesktop.ShipIt")
        let at = try e.attributor(apps: [claude])
        let first = at.attribute(u)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            #expect(at.attribute(u) == first)
        }
    }

    // MARK: ToolLocator, DownloadOrigin
    @Test func toolLocatorOrderAndInjection() throws {
        let e = try Env()
        let a = try e.dir("a"), b = try e.dir("b")
        for d in [a, b] {
            let f = d.appendingPathComponent("mytool")
            try "x".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        let l = ToolLocator(candidateDirectories: [a.path, b.path])
        #expect(l.locate("mytool") == a.path + "/mytool")
        #expect(l.locate("nope") == nil)
        #expect(l.locate("../a/mytool") == nil)
        let d = ToolLocator.defaultCandidateDirectories(home: e.home)
        #expect(d.first == e.home.standardizedFileURL.path + "/.local/bin" && d.last == "/usr/bin" && d.count == 5)
    }

    @Test func downloadOriginParsing() throws {
        let q = DownloadOrigin.parseQuarantine("0083;5f3e1a2b;Safari;ABCD-1234")
        #expect(q.agent == "Safari")
        #expect(q.date == Date(timeIntervalSince1970: 0x5f3e1a2b))
        let data = try PropertyListSerialization.data(fromPropertyList: ["https://a/b.zip", "https://a/"], format: .binary, options: 0)
        #expect(DownloadOrigin.parseWhereFroms(data) == ["https://a/b.zip", "https://a/"])
        // 실제 xattr 왕복
        let e = try Env()
        let f = e.home.appendingPathComponent("dl.zip")
        try "x".write(to: f, atomically: true, encoding: .utf8)
        let qs = "0083;5f3e1a2b;Chrome;U"
        #expect(setxattr(f.path, "com.apple.quarantine", qs, qs.utf8.count, 0, 0) == 0)
        let o = DownloadOrigin.lookup(f)
        #expect(o?.agentName == "Chrome")
        #expect(DownloadOrigin.lookup(e.home.appendingPathComponent("nonexistent")) == nil)
    }

    @Test func systemAppIndexFallbackEnumeration() throws {
        let idx = SystemAppIndex.build(useMetadataQuery: false)
        #expect(!idx.apps.isEmpty)
        #expect(idx.apps.allSatisfy { !$0.bundleID.isEmpty })
    }

    @Test func shortcutsGroupContainerAttribution() throws {
        let e = try Env()
        let a = try e.attributor().attribute(try e.dir("Library/Group Containers/group.is.workflow.my.app", ageDays: 90))
        #expect(a.appName == "단축어")
        #expect(a.subtitle == "macOS 시스템 앱")
        #expect(!a.isOrphanSuspect)
    }

    // MARK: 리포트 (SL_ATTR_REPORT=1 일 때만, 읽기 전용)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SL_ATTR_REPORT"] == "1"))
    func realHomeReport() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let rules = try loadRules()
        let idx = SystemAppIndex.build(vendorNames: rules.vendorNames)
        let at = Attributor(home: home, appIndex: idx, rules: rules, inUse: InUseIndex.snapshot())
        var exact = 0, inferred = 0, unknown = 0
        var orphans: [String] = []
        for sub in ["Caches", "Application Support", "Containers", "Group Containers"] {
            let dir = home.appendingPathComponent("Library/\(sub)")
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names {
                let a = at.attribute(dir.appendingPathComponent(n))
                if a.isOrphanSuspect { orphans.append("\(sub)/\(n)") }
                switch a.confidence {
                case .exact: exact += 1
                case .inferred: if !a.isOrphanSuspect { inferred += 1 }
                case .unknown: unknown += 1
                }
            }
        }
        print("REPORT: apps=\(idx.apps.count) known=\(idx.knownIdentifiers.count) running=\(idx.runningBundleIDs.count)")
        print("REPORT: 정확=\(exact) 추정=\(inferred) 알 수 없음=\(unknown) 고아 추정=\(orphans.count)")
        for o in orphans.sorted().prefix(30) { print("REPORT: orphan \(o)") }
    }
}

// MARK: - A3: 제조사 공용 그룹, 정규화, 상속 근거
extension AttributionTests {
    private static let chrome = InstalledApp(bundleID: "com.google.Chrome", displayName: "Chrome", vendorName: "Google")
    private static let drive = InstalledApp(bundleID: "com.google.Drive", displayName: "Drive", vendorName: "Google")

    @Test func vendorTokenWithTwoAppsIsSharedGroup() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/Google")
        for apps in [[Self.chrome, Self.drive], [Self.drive, Self.chrome]] {
            let a = try e.attributor(apps: apps).attribute(u)
            #expect(a.bundleID == "vendor:google")
            #expect(a.appName == "Google 공용")
            #expect(a.confidence == .inferred)
            #expect(a.iconSource == .none)
        }
    }

    @Test func vendorTokenWithOneAppAttributesToThatApp() throws {
        let e = try Env()
        let u = try e.dir("Library/Caches/Google")
        let a = try e.attributor(apps: [Self.chrome]).attribute(u)
        #expect(a.bundleID == "com.google.Chrome")
        #expect(a.appName == "Google")
    }

    @Test func exactVendorFolderBeatsPrefixMatchButExactAppNameWins() throws {
        let e = try Env()
        let chromeFull = InstalledApp(bundleID: "com.google.Chrome", displayName: "Google Chrome", vendorName: "Google")
        let driveFull = InstalledApp(bundleID: "com.google.Drive", displayName: "Google Drive", vendorName: "Google")
        let g = try e.dir("Library/Caches/Google")
        let gc = try e.dir("Library/Caches/Google Chrome")
        let two = try e.attributor(apps: [chromeFull, driveFull])
        #expect(two.attribute(g).bundleID == "vendor:google")
        #expect(two.attribute(gc).bundleID == "com.google.Chrome")
        // 설치 앱 1개뿐이면 기존 동작 (접두 매칭 -> 그 앱)
        let one = try e.attributor(apps: [chromeFull]).attribute(g)
        #expect(one.bundleID == "com.google.Chrome")
    }

    @Test func normalizeStripsTrailingVersionWithoutRegex() {
        #expect(Attributor.normalize("Adobe Camera Raw 2") == "adobecameraraw")
        #expect(Attributor.normalize("Foo-v3") == "foo")
        #expect(Attributor.normalize("Thing_2024") == "thing")
        #expect(Attributor.normalize("App 1.2.3") == "app")
        #expect(Attributor.normalize("2048") == "2048")
        #expect(Attributor.normalize("abc") == "abc")
        #expect(Attributor.normalize("a1b") == "a1b")
        #expect(Attributor.normalize("vv1") == "v")
    }

    @Test func inheritedRuleDoesNotAccumulate() throws {
        let e = try Env()
        let deep = try e.dir("Library/Caches/com.anthropic.claudefordesktop/a/b/c/d/e")
        let at = try e.attributor(apps: [claude])
        let a = at.attribute(deep)
        #expect(a.appName == "Claude")
        #expect(a.rule.contains("상속(5단계)"))
        #expect(a.rule.count < 120)
        #expect(a.rule.components(separatedBy: "상속").count == 2)
    }
}
