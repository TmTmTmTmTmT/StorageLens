import SwiftUI
import StorageCore

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.sidebar) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 170, max: 240)
        } detail: {
            Group {
                switch model.sidebar ?? .overview {
                case .overview: OverviewView(model: model)
                case .explore: ExploreView(model: model)
                case .apps: AppsView(model: model)
                case .icloud: ICloudView(model: model)
                case .journal: JournalView(model: model)
                }
            }
            // 배너·진행 카드는 콘텐츠 위에 떠 있고, 콘텐츠를 가리지 않도록 위쪽 공간을 확보한다.
            .safeAreaInset(edge: .top, spacing: 0) { FloatingStack(model: model) }
            .navigationSubtitle(subtitle)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.state == .scanning {
                    Button { model.cancelScan() } label: { Label("스캔 취소", systemImage: "xmark.circle") }
                        .help("스캔 취소 (⌘.)")
                } else {
                    Button { model.rescan() } label: {
                        Label(model.outcome == nil ? "스캔" : "재스캔", systemImage: "arrow.clockwise")
                    }
                    .help(model.outcome == nil ? "스캔 시작 (⌘R)" : "재스캔 (⌘R)")
                    .disabled(!model.canStartScan)
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { cleanupButton }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { model.windowSize = geo.size }
                    .onChange(of: geo.size) { _, new in model.windowSize = new }
            }
        )
        .sheet(item: Binding(get: { model.cleanupFlow },
                             set: { if $0 == nil { model.closeCleanup() } })) { flow in
            CleanupSheet(model: model, flow: flow)
        }
    }

    /// 정리 버튼: 탐색 화면에서 실행 가능할 때만 주 동작(.glassProminent), 그 외에는 기본 (화면당 강조 1개).
    @ViewBuilder private var cleanupButton: some View {
        let help = model.canCleanupSelection ? "선택 항목 정리 (⌘⌫)"
            : (model.sidebar == .explore ? (model.selectionCleanup.reason ?? "정리할 수 없습니다")
               : "탐색 화면에서 항목을 선택하세요")
        if model.sidebar == .explore, model.canCleanupSelection {
            Button { model.startCleanupForSelection() } label: { Label("정리…", systemImage: "trash") }
                .buttonStyle(.glassProminent)
                .help(help)
        } else {
            Button { model.startCleanupForSelection() } label: { Label("정리…", systemImage: "trash") }
                .help(help)
                .disabled(!model.canCleanupSelection)
        }
    }

    /// 창 부제목: 스캔 범위 · 마지막 스캔 시각.
    private var subtitle: String {
        guard let o = model.outcome else { return "" }
        let scope = o.logicalRootPath == "/" ? "전체 디스크" : o.logicalRootPath
        return "\(scope) · \(Fmt.dateTime(o.result.finishedAt))"
    }
}

/// 콘텐츠 위에 떠 있는 배너·진행 카드 스택. 내용이 없으면 공간을 차지하지 않는다.
/// 모든 카드는 하나의 GlassEffectContainer 안에서 세로로 쌓인다 (유리 안 유리 금지).
struct FloatingStack: View {
    @Bindable var model: AppModel

    private var isFailed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    private var isPartialScope: Bool {
        if let o = model.outcome { return o.logicalRootPath != "/" }
        return false
    }

    private var hasContent: Bool {
        model.fdaGrantedNotice != nil || model.showsPermissionBanner || isPartialScope
            || model.isBusy || isFailed
            || (model.rescanRecommended && model.outcome != nil)
            || !model.resourceWarnings.isEmpty || model.transientStatus != nil || !model.banners.isEmpty
    }

    var body: some View {
        if hasContent {
            GlassEffectContainer(spacing: Theme.panelSpacing) {
                VStack(spacing: Theme.panelSpacing) {
                    PermissionBanner(model: model)
                    ScopeBadge(model: model)
                    if model.isBusy || isFailed { ScanProgressCard(model: model) }
                    if model.rescanRecommended, model.outcome != nil { RescanBanner(model: model) }
                    BannerStack(model: model)
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        }
    }
}

/// 부분 모드(전체 디스크 접근 없음) 지속 배너 + 권한 허용 안내 (usability-6, design-13).
struct PermissionBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        if let msg = model.fdaGrantedNotice {
            FloatingBanner(.success, text: msg, systemImage: "checkmark.shield.fill") {
                if model.outcome != nil {
                    Button("재스캔") { model.rescan(); model.dismissGrantedNotice() }
                        .disabled(!model.canStartScan)
                }
                Button("닫기") { model.dismissGrantedNotice() }
            }
        } else if model.showsPermissionBanner {
            FloatingBanner(.warning,
                           text: model.fdaStatus == .undetermined
                           ? "전체 디스크 접근 권한을 확인하지 못했습니다. 일부 폴더를 읽지 못할 수 있습니다"
                           : "전체 디스크 접근 권한이 없어 일부 폴더를 읽지 못했습니다",
                           systemImage: "lock.trianglebadge.exclamationmark.fill") {
                Button("시스템 설정 열기") { model.openFullDiskAccessSettings() }
                Button("다시 확인") {
                    model.recheckFullDiskAccess()
                    if model.fdaStatus != .granted { model.showTransient("아직 권한이 허용되지 않았습니다") }
                }
            }
        }
    }
}

/// 폴더 지정(부분 범위) 스캔 결과일 때 상단에 범위를 표시하는 작은 유리 캡슐 (usability-15).
/// 범위는 창 부제목에도 표시된다.
struct ScopeBadge: View {
    @Bindable var model: AppModel

    var body: some View {
        if let o = model.outcome, o.logicalRootPath != "/" {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "scope").foregroundStyle(Theme.info).accessibilityHidden(true)
                Text("일부 범위 결과: \(o.logicalRootPath) — 전체 디스크 결과가 아닙니다")
                    .font(.callout).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Theme.Space.s)
                Button("전체 스캔") { model.startScan() }
                    .buttonStyle(.glass)
                    .disabled(!model.canStartScan)
            }
            .padding(.horizontal, Theme.panelPadding).padding(.vertical, Theme.Space.s)
            .glassEffect(.regular.tint(Theme.info.opacity(Theme.Opacity.glassTint)), in: Capsule())
            .accessibilityElement(children: .contain)
        }
    }
}

/// 비차단 배너 (이력·저널 저장 실패, 리소스 경고, 일시 상태 등, PLAN §16.6). 부모의 GlassEffectContainer 안에서 쌓인다.
struct BannerStack: View {
    @Bindable var model: AppModel

    var body: some View {
        ForEach(model.resourceWarnings, id: \.self) { text in
            FloatingBanner(.error, text: text)
        }
        if let t = model.transientStatus {
            FloatingBanner(.info, text: t)
        }
        ForEach(model.banners) { b in
            FloatingBanner(.warning, text: b.text) {
                Button("닫기") { model.dismissBanner(b.id) }
            }
        }
    }
}

/// 스캔 진행/실패를 보여 주는 떠 있는 유리 카드 (다른 화면 상단용).
struct ScanProgressCard: View {
    @Bindable var model: AppModel

    private var failed: Bool {
        if case .failed = model.state { return true }
        return false
    }

    var body: some View {
        ScanProgressDetail(model: model)
            .padding(Theme.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(failed ? Theme.discouraged.opacity(Theme.Opacity.glassTint) : nil),
                         in: Theme.panelShape)
    }
}

/// 진행 상세: 처리 항목 수 · 현재 경로 · 경과 시간 · 취소 · 실패 시 다시 시도/닫기.
/// 고빈도 텍스트(수치·경로·경과)는 VoiceOver에서 숨기고 상태 변화는 `announce`로 알린다.
struct ScanProgressDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.state {
        case .scanning:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).accessibilityLabel("스캔 중")
                    ScanProgressNumbers(model: model)
                    if let start = model.scanStartedAt {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            Text("경과 \(Fmt.elapsed(ctx.date.timeIntervalSince(start)))"
                                 + (model.lastScanDuration.map { " (지난번 약 \(Fmt.elapsed($0)))" } ?? ""))
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                    }
                    Spacer()
                    Button("취소", role: .cancel) { model.cancelScan() }.buttonStyle(.glass)
                }
                ScanProgressPath(model: model)
            }
        case .finishing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).accessibilityLabel("소속 앱·카테고리 계산 중")
                Text("소속 앱·카테고리 계산 중…").font(.callout)
                Spacer()
                Button("취소", role: .cancel) { model.cancelScan() }.buttonStyle(.glass).disabled(true)
            }
        case .failed(let msg):
            HStack(spacing: 10) {
                NoticeLabel(text: "스캔에 실패했습니다: \(msg)", systemImage: "xmark.octagon.fill",
                            color: Theme.discouraged, font: .callout)
                    .textSelection(.enabled)
                Spacer()
                HStack(spacing: Theme.Space.s) {
                    Button("다시 시도") { model.dismissScanFailure(); model.rescan() }
                        .disabled(!model.canStartScan)
                    Button("닫기") { model.dismissScanFailure() }
                }
                .buttonStyle(.glass)
            }
        case .idle:
            EmptyView()
        }
    }
}

/// 진행 수치만 관찰하는 하위 뷰 (150ms 갱신이 부모 body를 무효화하지 않도록).
private struct ScanProgressNumbers: View {
    var model: AppModel
    var body: some View {
        if let p = model.scanProgress {
            Text("스캔 중 · 항목 \(Fmt.count(p.itemCount))개 · \(Fmt.bytes(p.bytes))")
                .font(.callout.monospacedDigit())
                .accessibilityHidden(true)
        }
    }
}

private struct ScanProgressPath: View {
    var model: AppModel
    var body: some View {
        if let p = model.scanProgress {
            Text(p.currentPath).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityHidden(true)
        }
    }
}

/// 스캔 시작/취소 + 진행 표시
struct ScanControlBar: View {
    @Bindable var model: AppModel
    @State private var pickingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !model.isBusy {
                HStack {
                    Button("스캔 시작") { model.startScan() }
                        .buttonStyle(.glassProminent)
                        .disabled(!model.canStartScan)
                    Button("폴더 지정 스캔…") { pickingFolder = true }
                        .buttonStyle(.glass)
                        .disabled(!model.canStartScan)
                    if let o = model.outcome {
                        Text("마지막 스캔: \(o.logicalRootPath) · \(Fmt.date(o.result.finishedAt))" +
                             (o.skippedCount > 0 ? " · 접근 불가 \(Fmt.count(o.skippedCount))곳" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { r in
            if case .success(let url) = r { model.startScan(root: url.path) }
        }
    }
}

/// 스캔 결과가 없을 때의 공통 빈 상태.
struct NoScanView: View {
    @Bindable var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ScanControlBar(model: model)
        }
        .padding(24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
