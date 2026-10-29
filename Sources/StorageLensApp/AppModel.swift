import SwiftUI
import AppKit
import StorageCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, explore, apps, icloud, journal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "개요"
        case .explore: "탐색"
        case .apps: "앱별"
        case .icloud: "iCloud"
        case .journal: "정리 기록"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "chart.bar.fill"
        case .explore: "circle.hexagongrid.fill"
        case .apps: "square.grid.2x2.fill"
        case .icloud: "icloud.fill"
        case .journal: "clock.arrow.circlepath"
        }
    }
    static let defaultsKey = "StorageLens.lastSidebar"
    static func restore() -> SidebarItem {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SidebarItem.init(rawValue:)) ?? .overview
    }
}

/// iCloud 업로드 대기 조회 상태 (컨테이너 선택 시 자동 시작).
enum PendingUploadState: Equatable {
    case idle
    case running
    case done(pending: Int, checked: Int, truncated: Bool)
}

/// 스캔 상태. 진행 수치는 `AppModel.scanProgress`로 분리되어 있어(perf-3) 이 값은 상태 전이 때만 바뀐다.
enum ScanState: Equatable {
    case idle
    case scanning
    case finishing
    case failed(String)
}

/// 개요 화면용 사전 계산 결과 (스캔 완료 시 백그라운드에서 1회 계산, perf-14).
/// OverviewView 의 categorySection 이 body 에서 하던 계산과 같은 결과다.
struct OverviewCategories: Sendable {
    struct Row: Sendable, Identifiable {
        /// 카탈로그 항목 id (미분류는 `CategoryTotals.otherID`).
        let id: String
        /// 표시 이름 (`AppModel.categoryTitle`과 동일).
        let title: String
        let size: Int64
        /// 카탈로그에 있는 카테고리면 안전 등급, 없으면 nil.
        let safety: Safety?
    }
    struct Virtual: Sendable, Identifiable {
        var id: String { entry.id }
        let entry: CatalogEntry
        let availability: CleanupAvailability
    }
    /// iCloud 로컬 사본(`icloud-local`)을 뺀 카테고리, 크기 내림차순.
    let rows: [Row]
    /// 가상 항목(`icloud-local` 제외)과 `virtualAvailability` 결과.
    let virtualItems: [Virtual]
}

/// 정리 시트 한 번의 흐름: 계획(InUse 재조회) -> 미리보기 -> 실행 -> 결과.
/// 단계 전이는 `CleanupFlowMachine`(StorageCore)이 판정한다.
@MainActor
@Observable
final class CleanupFlow: Identifiable {
    let id = UUID()
    let title: String
    let paths: [String]
    let virtualEntry: CatalogEntry?
    /// "비권장 항목임을 이해했습니다" 체크 (PLAN §16.1).
    var acknowledged = false
    var machine = CleanupFlowMachine()
    var phase: CleanupFlowMachine.Phase { machine.phase }
    var plan: CleanupPlan?
    var result: CleanupResult?
    var cleaner: Cleaner?
    /// 계획·실행 진행 (150ms 이하로 합쳐 반영).
    var progress: CleanupProgress?
    /// 비표준 경로에서 발견된 도구의 경로 (미리보기 경고용).
    var nonStandardToolPaths: Set<String> = []

    init(title: String, paths: [String], virtualEntry: CatalogEntry?) {
        self.title = title; self.paths = paths; self.virtualEntry = virtualEntry
    }
}

/// 백그라운드 진행 콜백을 최대 interval 간격으로 합쳐 메인 액터에 전달한다.
final class ProgressCoalescer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: T?
    private var scheduled = false
    private let interval: TimeInterval
    private let apply: @MainActor (T) -> Void

    init(interval: TimeInterval = 0.15, apply: @escaping @MainActor (T) -> Void) {
        self.interval = interval; self.apply = apply
    }

    func push(_ value: T) {
        lock.lock()
        latest = value
        let needSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard needSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [self] in
            lock.lock()
            let v = latest; latest = nil; scheduled = false
            lock.unlock()
            if let v { MainActor.assumeIsolated { apply(v) } }
        }
    }
}

/// 실행 중 앱 종료 시 확인 (SwiftUI App에 `@NSApplicationDelegateAdaptor`로 연결해야 동작; StorageLensApp.swift는 B1 소유).
@MainActor
final class AppTerminationGuard: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.active?.isExecutingCleanup == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "정리가 실행 중입니다"
        alert.informativeText = "지금 종료하면 일부 항목만 처리된 채 끝납니다. 처리된 항목은 정리 기록에 남습니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "계속 실행")
        alert.addButton(withTitle: "그래도 종료")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

@MainActor
@Observable
final class AppModel {
    /// 종료 확인(AppTerminationGuard)이 참조하는 현재 모델.
    static weak var active: AppModel?
    private let session = StorageSession()

    var sidebar: SidebarItem? = SidebarItem.restore() {
        didSet { if let sidebar { UserDefaults.standard.set(sidebar.rawValue, forKey: SidebarItem.defaultsKey) } }
    }
    var state: ScanState = .idle
    /// 스캔 진행 수치 (150ms 간격으로 합쳐 갱신). 상태(`state`)와 별도로 관찰된다.
    var scanProgress: ScanProgress?
    /// 지난 스캔(같은 루트) 소요 시간 — 진행 스트립 참고 표시용. 코어 이력에 소요 시간이 없어 앱이 직접 보관.
    var lastScanDuration: TimeInterval?
    /// 개요용 사전 계산 (스캔 완료 시 1회, 완료 전/스캔 결과 없음은 nil).
    var overviewCategories: OverviewCategories?
    var outcome: ScanOutcome?
    var volume: VolumeInfo? = VolumeInfo.read()
    var scanRoot: String = StorageSession.defaultRoot

    // 탐색
    var focusPath: String = "/"
    var sort: RowSort = .size
    var rows: [NodeRow] = []
    var arcs: [SunburstArc] = []
    var selectedPath: String?
    var selection: Set<String> = []
    /// rows/arcs 가 마지막으로 반영된 폴더 (F11-2). focusPath 와 다르면 목록·차트가 이전 폴더 것이다.
    private(set) var rowsFocusPath: String?
    /// 새 폴더 rows 가 도착하기 전에 요청된 선택 (도착 후 현재 rows 에 있는 경로만 적용, F11-1).
    private var pendingSelection: Set<String>?
    /// 되돌리기 진행 중인 기록 행 id (중복 클릭 무시, F11-7).
    private(set) var undoingRowIDs: Set<Int> = []
    var availabilities: [String: CleanupAvailability] = [:]

    // 정리
    var cleanupFlow: CleanupFlow?
    var rescanRecommended = false
    var journalRows: [JournalRow] = []
    var journalLoading = false
    /// 정리 실행 중 (새 정리 시작 차단·종료 경고).
    var isExecutingCleanup = false
    /// 잠깐 보이는 상태 문구 (예: 스캔 취소).
    var transientStatus: String?
    var undoMessage: String?
    /// 마지막 되돌리기 결과 (행 id + 메시지 + 일련번호). 같은 문구가 반복돼도 매번 새 값이라 행에 반영된다.
    var lastUndo: UndoFeedback?
    private var undoSeq = 0
    /// 탐색 검색 필드가 편집 중인가 (⌘⌫·⌘↑ 메뉴 명령이 글자 편집을 가로채지 않도록).
    var isSearchFocused = false
    /// 온보딩 "다시 확인" 후에도 권한이 없을 때의 인라인 안내.
    var onboardingNotice: String?
    var detail: NodeDetail?
    var origin: DownloadOrigin?
    var originLoading = false

    // 창 크기 (시트 비례 크기용)
    /// ⌘F 마다 증가. 탐색 화면(B2)이 관찰해 검색 필드에 포커스를 준다.
    var searchFocusRequest: Int = 0

    // 전체 디스크 접근 (FDA)
    var fdaStatus: FDAStatus = FullDiskAccess.check(home: FileManager.default.homeDirectoryForCurrentUser)
    /// 온보딩에서 "부분 스캔으로 계속"을 선택함.
    var continuePartial = false {
        didSet { if continuePartial && !oldValue && fdaStatus != .granted { announce("전체 디스크 접근 권한이 없어 일부 폴더를 읽지 못할 수 있습니다") } }
    }
    /// 권한이 앱 사용 중 허용됨 -> "재스캔하세요" 안내 표시.
    var fdaGrantedNotice: String?

    var windowSize: CGSize = CGSize(width: 1000, height: 700)
    // 스캔 시작 시각 (경과 시간 표시)
    var scanStartedAt: Date?
    // 비차단 하단 배너 (저장 실패 등)
    var banners: [AppBanner] = []

    // 앱별
    var appGroups: [AppDataGroup] = []
    var appGroupsLoading = false

    // iCloud
    var icloud: ICloudInventory?
    var selectedContainerPath: String?
    var subfolders: [ICloudFolder] = []
    var pendingState: PendingUploadState = .idle

    private var scanTask: Task<Void, Never>?
    private var rowsTask: Task<Void, Never>?
    private var exploreGate = GenerationGate()
    private var originTask: Task<Void, Never>?
    private var appGroupsTask: Task<Void, Never>?
    private var icloudTask: Task<Void, Never>?
    private var pendingTask: Task<Void, Never>?
    private var planTask: Task<Void, Never>?
    private var executeTask: Task<Void, Never>?
    private var transientTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var overviewTask: Task<Void, Never>?
    /// 직전 결과를 만든 스캔 루트 (재스캔 시 focusPath 복원 판단).
    private var outcomeScanRoot: String?
    private var restoreFocusPath: String?
    private var notifiedHistoryCorrupt = 0
    private var notifiedHistoryFuture = 0
    private var notifiedJournalCorrupt = 0

    /// 현재 목록·차트가 focusPath 의 것인가 (false 면 흐림 + 상호작용 차단).
    var rowsMatchFocus: Bool { rowsFocusPath == focusPath }

    var isBusy: Bool {
        if case .scanning = state { return true }
        return state == .finishing
    }

    /// 스캔을 시작할 수 있는가 (스캔 중·정리 시트·정리 실행 중·온보딩 미완료면 false). 메뉴·툴바·배너 공용.
    var canStartScan: Bool {
        ScanGate.canStartScan(isBusy: isBusy, hasCleanupFlow: cleanupFlow != nil,
                              isExecutingCleanup: isExecutingCleanup, canProceed: canProceed)
    }

    /// 화면 전환·상위 이동 등 상태를 바꾸는 명령 허용 여부 (정리 시트가 열려 있으면 불가).
    var canNavigate: Bool { canProceed && cleanupFlow == nil && !isExecutingCleanup }

    var resourcesMissing: Bool { !session.hasRules || !session.hasCatalog }

    /// 카탈로그·규칙 로드 상태 경고 (지속 배너; 닫을 수 없음).
    var resourceWarnings: [String] {
        var out: [String] = []
        if let m = session.catalogLoadStatus.message {
            let tail = session.hasCatalog ? "" : " 정리 기능이 비활성화됩니다."
            out.append("정리 안내 목록(catalog.json) 문제: \(m)\(tail)")
        } else if !session.hasCatalog {
            out.append("정리 안내 목록이 비어 있습니다. 정리 기능이 비활성화됩니다.")
        }
        if let m = session.rulesLoadStatus.message {
            out.append("앱 구성 파일 문제: \(m) 소속 앱 판단이 부정확할 수 있습니다.")
        }
        return out
    }

    func showTransient(_ text: String) {
        transientStatus = text
        announce(text)
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.transientStatus = nil
        }
    }

    init() { Self.active = self }

    func startScan(root: String = StorageSession.defaultRoot) {
        guard canStartScan else { return }
        // 같은 루트의 재스캔이면 끝난 뒤 현재 탐색 위치를 복원한다 (usability-5).
        restoreFocusPath = (outcome != nil && outcomeScanRoot == root) ? focusPath : nil
        scanRoot = root
        scanProgress = ScanProgress(itemCount: 0, bytes: 0, currentPath: root)
        state = .scanning
        scanStartedAt = Date()
        lastScanDuration = UserDefaults.standard.object(forKey: Self.durationKey(root)) as? Double
        announce("스캔을 시작했습니다")
        let running = Self.runningBundleIDs()
        let session = self.session
        // 진행 콜백을 150ms 간격으로 합쳐 메인에 반영 (perf-3).
        let coalescer = ProgressCoalescer<ScanProgress> { [weak self] p in
            guard let self, self.state == .scanning else { return }
            self.scanProgress = p
        }
        scanTask = Task { [self] in
            do {
                let out = try await session.scan(root: root, runningBundleIDs: running) { p in
                    coalescer.push(p)
                } onFinishing: {
                    Task { @MainActor in
                        guard self.state == .scanning else { return }
                        self.state = .finishing
                        self.scanProgress = nil
                    }
                }
                finish(out, root: root)
            } catch is CancellationError {
                state = .idle
                scanProgress = nil
                scanStartedAt = nil
                restoreFocusPath = nil
                showTransient("스캔을 취소했습니다")
            } catch {
                state = .failed(error.localizedDescription)
                scanProgress = nil
                scanStartedAt = nil
                restoreFocusPath = nil
                announce("스캔에 실패했습니다: \(error.localizedDescription)")
            }
        }
    }

    private static func durationKey(_ root: String) -> String { "StorageLens.lastScanDuration.\(root)" }

    /// 실패 표시를 닫는다.
    func dismissScanFailure() {
        if case .failed = state { state = .idle }
    }

    /// 현재 스캔 루트로 다시 스캔 (완료 후 탐색 위치 복원). 스캔 중이면 무시.
    func rescan() { startScan(root: scanRoot) }

    func cancelScan() { scanTask?.cancel() }

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func addBanner(_ text: String) {
        guard !banners.contains(where: { $0.text == text }) else { return }
        banners.append(AppBanner(text: text))
        announce(text)
    }

    func dismissBanner(_ id: UUID) { banners.removeAll { $0.id == id } }

    private func finish(_ out: ScanOutcome, root: String) {
        outcome = out
        outcomeScanRoot = root
        scanStartedAt = nil
        scanProgress = nil
        let dur = out.result.finishedAt.timeIntervalSince(out.result.startedAt)
        if dur > 0 { UserDefaults.standard.set(dur, forKey: Self.durationKey(root)) }
        if let e = out.historySaveError { addBanner(e) }
        let corrupt = session.historyCorruptCount
        if corrupt > notifiedHistoryCorrupt {
            notifiedHistoryCorrupt = corrupt
            addBanner("손상된 스캔 기록 \(corrupt)건을 격리했습니다")
        }
        let future = session.historyFutureVersionSkippedCount
        if future > notifiedHistoryFuture {
            notifiedHistoryFuture = future
            addBanner("더 새로운 버전에서 만든 스캔 기록 \(future)건은 건너뛰었습니다")
        }
        appGroups = []; icloud = nil; selectedContainerPath = nil; subfolders = []
        pendingTask?.cancel(); pendingState = .idle
        refreshAppGroups(); refreshICloud()
        rescanRecommended = false
        volume = out.volume ?? VolumeInfo.read()
        state = .idle
        let target = restoreFocusPath.map { Self.nearestExisting($0, in: out) } ?? out.logicalRootPath
        restoreFocusPath = nil
        focusPath = target
        selectedPath = nil; detail = nil; origin = nil
        availabilityTask?.cancel()
        selection = []; availabilities = [:]
        pendingSelection = nil; rowsFocusPath = nil
        reloadExplore()
        computeOverview(out)
        announce("스캔이 완료되었습니다. 총 \(Fmt.bytes(out.result.root.allocatedSize))")
    }

    /// path 가 트리에 있으면 path, 없으면 가장 가까운 존재하는 상위 (최악의 경우 루트).
    private static func nearestExisting(_ path: String, in o: ScanOutcome) -> String {
        var p = path
        while o.node(at: p) == nil {
            guard let up = o.parentPath(of: p) else { return o.logicalRootPath }
            p = up
        }
        return p
    }

    /// 개요 카테고리·가상 항목 가용성을 백그라운드에서 1회 계산 (perf-14).
    private func computeOverview(_ o: ScanOutcome) {
        overviewTask?.cancel()
        overviewCategories = nil
        overviewTask = Task { [weak self] in
            let r = await Task.detached { () -> OverviewCategories in
                let rows = o.categoryTotals.filter { $0.key != "icloud-local" }
                    .sorted { $0.value > $1.value }
                    .map { (id, size) -> OverviewCategories.Row in
                        let e = o.catalog.entry(id: id)
                        let title = id == CategoryTotals.otherID ? "기타 (분류 없음)" : (e?.title ?? id)
                        return .init(id: id, title: title, size: size, safety: e?.safety)
                    }
                let virtuals = o.catalog.virtualEntries.filter { $0.id != "icloud-local" }
                    .map { OverviewCategories.Virtual(entry: $0, availability: o.virtualAvailability($0)) }
                return OverviewCategories(rows: rows, virtualItems: virtuals)
            }.value
            guard !Task.isCancelled, let self, self.outcome === o else { return }
            self.overviewCategories = r
        }
    }

    // MARK: - 명령·흐름 (B1 공개 API)

    /// 사이드바 화면 이동.
    func navigate(to section: SidebarItem) {
        guard cleanupFlow == nil, !isExecutingCleanup else { return }
        sidebar = section
    }

    /// 탐색 화면으로 이동해 path 를 포커스한다. 폴더면 그 폴더, 파일이면 상위 폴더 포커스 + 파일 선택.
    /// 트리에 없으면 가장 가까운 존재하는 상위 폴더. 스캔 결과가 없으면 화면 이동만 한다.
    func reveal(path: String) {
        navigate(to: .explore)
        guard let o = outcome else { return }
        let near = Self.nearestExisting(path, in: o)
        guard let node = o.node(at: near) else { return }
        if node.isDirectory {
            focus(near)
        } else {
            let parent = o.parentPath(of: near) ?? o.logicalRootPath
            if parent != focusPath { focus(parent) }
            if near == path { setSelection([near]) }
        }
    }

    /// 탐색 화면의 상위 폴더로 이동 (⌘↑). 루트면 무시.
    func goUp() { focusUp() }

    var canGoUp: Bool {
        guard sidebar == .explore, let o = outcome else { return false }
        return o.parentPath(of: focusPath) != nil
    }

    /// ⌘↑ 메뉴 명령 활성 조건 (검색 필드 편집 중·정리 진행 중이면 불가).
    var canGoUpCommand: Bool { canGoUp && !isSearchFocused && canNavigate }

    /// ⌘⌫ 메뉴 명령 활성 조건 (검색 필드 편집 중이면 글자 삭제에 양보).
    var canCleanupCommand: Bool { canCleanupSelection && !isSearchFocused }

    /// 탐색 화면에서 선택 항목이 정리 가능한가 (메뉴·툴바 활성 조건).
    var canCleanupSelection: Bool {
        sidebar == .explore && !isBusy && canStartCleanup && selectionCleanup.enabled
    }

    /// 현재 선택으로 정리 시트 시작. 불가하면 무시.
    func startCleanupForSelection() {
        guard canCleanupSelection else { return }
        beginCleanup(paths: Array(selection))
    }

    /// 전체 디스크 접근 상태를 다시 확인. 앱 활성화 시 자동 호출된다.
    /// 온보딩 "다시 확인" 버튼: 재확인 후 여전히 미허용이면 인라인 문구 + 공지.
    func recheckFromOnboarding() {
        recheckFullDiskAccess()
        if fdaStatus == .granted {
            onboardingNotice = nil
        } else {
            let msg = fdaStatus == .denied
                ? "아직 전체 디스크 접근이 허용되지 않았습니다. 시스템 설정에서 허용한 뒤 다시 확인하세요."
                : "권한 상태를 확인하지 못했습니다. 시스템 설정에서 허용했는지 확인한 뒤 다시 시도하세요."
            onboardingNotice = msg
            announce(msg)
        }
    }

    func recheckFullDiskAccess() {
        let old = fdaStatus
        let new = FullDiskAccess.check(home: FileManager.default.homeDirectoryForCurrentUser)
        fdaStatus = new
        if new == .granted, old != .granted, continuePartial || old == .undetermined {
            let msg = outcome != nil ? "권한이 허용되었습니다. 재스캔하세요" : "권한이 허용되었습니다. 스캔을 시작하세요"
            fdaGrantedNotice = msg
            announce(msg)
        }
    }

    /// 부분 모드 지속 배너 표시 여부 (FDA 미허용으로 계속 중이거나 상태 확인 불가).
    var showsPermissionBanner: Bool { canProceed && fdaStatus != .granted }
    var canProceed: Bool { fdaStatus != .denied || continuePartial }

    func dismissGrantedNotice() { fdaGrantedNotice = nil }

    /// 앱 다시 시작 가능 여부 (정리 실행 중이면 불가 — AppTerminationGuard 종료 경고와 충돌 방지).
    var canRestartApp: Bool { !isExecutingCleanup }

    /// 현재 번들을 새 인스턴스로 연 뒤 이 인스턴스를 종료한다.
    func restartApp() {
        guard canRestartApp else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.addBanner("앱을 다시 시작하지 못했습니다: \(error.localizedDescription)")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// VoiceOver 공지 (우선순위 high).
    func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func focus(_ path: String) {
        focusPath = path
        selectedPath = nil; detail = nil; origin = nil
        availabilityTask?.cancel()
        selection = []; availabilities = [:]
        pendingSelection = nil
        reloadExplore()
    }

    func focusUp() {
        if let o = outcome, let p = o.parentPath(of: focusPath) { focus(p) }
    }

    func setSort(_ s: RowSort) { sort = s; reloadExplore() }

    private func reloadExplore() {
        // 이전 작업은 실제로 취소하고(작업 내부 isCancelled 확인), 세대 토큰으로 낡은 결과도 폐기한다.
        rowsTask?.cancel()
        let gen = exploreGate.advance()
        guard let o = outcome else { rowsTask = nil; rows = []; arcs = []; rowsFocusPath = nil; return }
        let path = focusPath, sort = self.sort
        // rows 와 arcs 를 같은 취소 가능 detached 작업에서 계산해 한 번에 반영 (perf-1).
        rowsTask = Task.detached(priority: .userInitiated) { [weak self] in
            let r = o.rows(focusPath: path, sort: sort)
            if Task.isCancelled { return }
            let a = o.sunburst(focusPath: path)
            if Task.isCancelled { return }
            await self?.applyExplore(generation: gen, outcome: o, path: path, rows: r, arcs: a)
        }
    }

    private func applyExplore(generation: Int, outcome o: ScanOutcome, path: String, rows r: [NodeRow], arcs a: [SunburstArc]) {
        guard exploreGate.isCurrent(generation), outcome === o else { return }
        rows = r
        arcs = a
        rowsFocusPath = path
        if let pending = pendingSelection, path == focusPath {
            pendingSelection = nil
            setSelection(pending)
        }
    }

    /// 목록 다중 선택. 단일 선택이면 상세 패널도 갱신.
    func setSelection(_ requested: Set<String>) {
        // 새 폴더 rows 가 아직 없으면 도착 후 적용한다.
        if requested.isEmpty { pendingSelection = nil }
        else if !rowsMatchFocus { pendingSelection = requested; return }
        // 현재 목록에 없는 경로는 선택할 수 없다 (보이지 않는 항목 정리 방지, F11-1).
        let visible = Set(rows.lazy.filter { !$0.isOmittedSummary }.map(\.path))
        let s = requested.intersection(visible)
        selection = s
        availabilities = [:]
        select(s.count == 1 ? s.first : nil)
        availabilityTask?.cancel()
        guard let o = outcome, !s.isEmpty else { return }
        let paths = s
        // 이전 계산은 취소하고 최신 선택만 계산한다 (perf-10).
        availabilityTask = Task { [weak self] in
            let work = Task.detached { () -> [String: CleanupAvailability]? in
                var d: [String: CleanupAvailability] = [:]
                for p in paths {
                    if Task.isCancelled { return nil }
                    d[p] = o.cleanupAvailability(forPath: p)
                }
                return d
            }
            let av = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, let av, let self, self.selection == paths else { return }
            self.availabilities = av
        }
    }

    /// 선택 항목에 대한 정리 버튼 상태 (비활성이면 사유 포함).
    var selectionCleanup: (enabled: Bool, reason: String?) {
        guard !selection.isEmpty else { return (false, "항목을 선택하세요") }
        guard selection.allSatisfy({ availabilities[$0] != nil }) else { return (false, "확인 중…") }
        let avs = selection.compactMap { availabilities[$0] }
        if let bad = avs.first(where: { !$0.enabled }) {
            return (false, avs.count > 1 ? "\((bad.path as NSString).lastPathComponent): \(bad.reason ?? "정리 불가")" : bad.reason)
        }
        return (true, nil)
    }

    func select(_ path: String?) {
        selectedPath = path
        detail = nil; origin = nil; originTask?.cancel()
        guard let path, let o = outcome else { return }
        originLoading = true
        originTask = Task { [weak self] in
            let (d, org) = await Task.detached { (o.detail(forPath: path), StorageSession.downloadOrigin(path: path)) }.value
            guard !Task.isCancelled else { return }
            self?.detail = d; self?.origin = org; self?.originLoading = false
        }
    }

    func openTrashInFinder() {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trash)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 카탈로그 항목 id -> 표시 이름
    func categoryTitle(_ id: String) -> String {
        if id == CategoryTotals.otherID { return "기타 (분류 없음)" }
        return outcome?.catalog.entry(id: id)?.title ?? id
    }

    // MARK: - 정리

    func beginCleanup(paths: [String]) {
        guard !paths.isEmpty, canStartCleanup else { return }
        let title = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(Fmt.count(paths.count))개 항목"
        startFlow(CleanupFlow(title: title, paths: paths.sorted(), virtualEntry: nil))
    }

    func beginVirtualCleanup(_ entry: CatalogEntry) {
        guard canStartCleanup else { return }
        startFlow(CleanupFlow(title: entry.title, paths: [], virtualEntry: entry))
    }

    private var canStartCleanup: Bool { !isBusy && cleanupFlow == nil && !isExecutingCleanup }

    /// 시트를 열 때(그리고 다시 계획할 때) InUse를 새로 조회해 계획을 만든다.
    func startFlow(_ flow: CleanupFlow) {
        guard flow.machine.send(.begin) else { return }
        cleanupFlow = flow
        runPlanning(flow)
    }

    func replan(_ flow: CleanupFlow) {
        guard flow.machine.send(.replan) else { return }
        runPlanning(flow)
    }

    private func runPlanning(_ flow: CleanupFlow) {
        flow.acknowledged = false
        flow.result = nil; flow.plan = nil; flow.progress = nil
        let session = self.session, o = outcome
        let paths = flow.paths, virtual = flow.virtualEntry
        let coalescer = ProgressCoalescer<CleanupProgress> { [weak flow] p in
            guard let flow, flow.phase == .planning else { return }
            flow.progress = p
        }
        planTask?.cancel()
        planTask = Task {
            let work = Task.detached { () -> (Cleaner, CleanupPlan, Set<String>) in
                let cleaner = session.makeCleaner(outcome: o, inUse: InUseIndex.snapshot())
                var sels = paths.map { CleanupSelection(path: $0) }
                if let v = virtual, let o { sels = [o.virtualSelection(v)] }
                let plan = cleaner.plan(sels, progress: { coalescer.push($0) })
                let nonStd = Set(plan.items.filter { session.isNonStandardTool($0) }.compactMap(\.toolPath))
                return (cleaner, plan, nonStd)
            }
            let (cleaner, plan, nonStd) = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            // 취소·닫힘 후 늦게 도착한 결과는 머신이 거부한다.
            guard !Task.isCancelled, flow.machine.send(.planFinished) else { return }
            flow.cleaner = cleaner; flow.plan = plan; flow.nonStandardToolPaths = nonStd
            flow.progress = nil
            let total = plan.items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            announce(plan.items.isEmpty ? "정리할 항목 없음"
                     : "정리 계획 준비: \(Fmt.count(plan.items.count))개, 합계 \(Fmt.bytes(total))")
        }
    }

    func confirmCleanup(_ flow: CleanupFlow) {
        guard let cleaner = flow.cleaner, let plan = flow.plan, !isExecutingCleanup,
              flow.machine.send(.confirm) else { return }
        isExecutingCleanup = true
        flow.progress = nil
        let ack = flow.acknowledged
        let coalescer = ProgressCoalescer<CleanupProgress> { [weak flow] p in
            guard let flow, flow.phase == .executing else { return }
            flow.progress = p
        }
        executeTask = Task { [weak self] in
            let result = await cleaner.execute(plan, acknowledgedDiscouraged: ack, progress: { coalescer.push($0) })
            guard let self else { return }
            flow.result = result
            flow.progress = nil
            for je in Set(result.outcomes.compactMap(\.journalError)) { addBanner(je) }
            flow.machine.send(.executionFinished(planExpired: result.planExpired))
            isExecutingCleanup = false
            executeTask = nil
            if result.outcomes.contains(where: { $0.status == .succeeded || $0.status == .partial }) {
                rescanRecommended = true
            }
            let ok = result.outcomes.filter { $0.status == .succeeded }.count
            let part = result.outcomes.filter { $0.status == .partial }.count
            let bad = result.outcomes.count - ok - part
            announce("정리가 끝났습니다. 성공 \(Fmt.count(ok))개" + (part > 0 ? ", 일부 성공 \(Fmt.count(part))개" : "") + (bad > 0 ? ", 건너뜀·실패 \(Fmt.count(bad))개" : ""))
        }
    }

    /// 모든 닫힘 경로의 단일 진입점 (버튼·Esc·바인딩). 실행 중에는 거부된다.
    func closeCleanup() {
        guard let flow = cleanupFlow else { return }
        guard flow.machine.send(.close) else { return }
        planTask?.cancel(); planTask = nil
        cleanupFlow = nil
        if sidebar == .journal { loadJournal() }
    }

    /// planning 단계의 "취소" 버튼.
    func cancelCleanupPlanning() { closeCleanup() }

    // MARK: - 정리 기록

    func loadJournal() {
        journalLoading = true
        let session = self.session
        Task {
            let load = await Task.detached {
                StorageSession.journalLoad(cleaner: session.makeCleaner(outcome: nil))
            }.value
            journalRows = load.rows
            journalLoading = false
            if load.corruptLineCount > notifiedJournalCorrupt {
                notifiedJournalCorrupt = load.corruptLineCount
                addBanner("정리 기록에서 손상된 줄 \(load.corruptLineCount)건을 건너뛰었습니다")
            }
        }
    }

    func undo(_ row: JournalRow) {
        guard undoingRowIDs.insert(row.id).inserted else { return }
        let session = self.session
        let entry = row.entry
        let rowID = row.id
        lastUndo = nil
        Task {
            let res = await Task.detached { session.makeCleaner(outcome: nil).undo(entry) }.value
            undoingRowIDs.remove(rowID)
            let m = res.success ? "되돌렸습니다: \(entry.originalPath)" : "되돌리기 실패: \(res.reason ?? "알 수 없는 이유")"
            undoMessage = m
            undoSeq += 1
            lastUndo = UndoFeedback(rowID: rowID, message: m, seq: undoSeq)
            announce(m)
            if res.success { rescanRecommended = true }
            loadJournal()
        }
    }
}


/// 되돌리기 결과 피드백 (행 id 기준, seq 로 같은 문구 반복도 구분).
struct UndoFeedback: Equatable {
    let rowID: Int
    let message: String
    let seq: Int
}

struct AppBanner: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

// MARK: - 앱별 · iCloud (계산은 메인 액터 밖, 결과만 캐시)

extension AppModel {
    func refreshAppGroups() {
        guard let o = outcome else { appGroups = []; return }
        let running = Self.runningBundleIDs()
        appGroupsTask?.cancel()
        appGroupsLoading = true
        appGroupsTask = Task { [weak self] in
            let g = await Task.detached { o.appDataGroups(runningBundleIDs: running) }.value
            guard !Task.isCancelled, let self else { return }
            self.appGroups = g
            self.appGroupsLoading = false
        }
    }

    func refreshICloud() {
        guard let o = outcome else { icloud = nil; return }
        icloudTask?.cancel()
        icloudTask = Task { [weak self] in
            let inv = await Task.detached { o.iCloudInventory() }.value
            guard !Task.isCancelled, let self else { return }
            self.icloud = inv
        }
    }

    /// 컨테이너 선택: 하위 폴더 목록 + 업로드 대기 조회를 자동 시작.
    func selectContainer(_ path: String?) {
        pendingTask?.cancel()
        selectedContainerPath = path
        subfolders = []
        pendingState = .idle
        guard let path, let o = outcome, let inv = icloud else { return }
        pendingState = .running
        pendingTask = Task { [weak self] in
            let subs = await Task.detached { inv.subfolders(ofContainer: path, in: o) }.value
            guard !Task.isCancelled, let self, self.selectedContainerPath == path else { return }
            self.subfolders = subs
            let r = await ICloudInventory.pendingUploads(containerPath: path)
            guard !Task.isCancelled, self.selectedContainerPath == path else { return }
            self.pendingState = .done(pending: r.pending, checked: r.checked, truncated: r.truncated)
        }
    }

    func cancelPendingCheck() {
        pendingTask?.cancel()
        pendingState = .idle
    }
}
