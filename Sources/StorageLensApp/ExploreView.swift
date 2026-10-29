import SwiftUI
import StorageCore

struct ExploreView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var scheme
    @State private var hover = ExploreHover()
    @State private var query = ""
    @State private var sortChoice: ExploreSortChoice
    @State private var chipInUse = false
    @State private var chipDiscouraged = false
    @State private var chipOrphan = false
    @State private var discouragedPaths: Set<String> = []
    @State private var showInspector = false
    @FocusState private var searchFocused: Bool

    /// 현재 폴더 자식이 표시 한도를 넘어 상위 일부만 목록에 있는가 (F11-3).
    private var truncatedCount: Int? {
        guard let n = model.outcome?.node(at: model.focusPath)?.children.count,
              n > ScanOutcome.rowTruncateThreshold else { return nil }
        return n - ScanOutcome.rowKeepCount
    }
    private var truncationCaption: String? {
        truncatedCount.map { "상위 \(Fmt.count(ScanOutcome.rowKeepCount))개 안에서만 검색·정렬됩니다. 나머지 \(Fmt.count($0))개는 Finder에서 확인" }
    }

    /// 콘텐츠 폭이 이보다 좁으면 선버스트를 목록 위에 쌓는다 (단일 기준, design-3).
    static let compactWidth: CGFloat = 600

    init(model: AppModel) {
        self.model = model
        _sortChoice = State(initialValue: model.sort == .modified ? .modified : .size)
    }

    var body: some View {
        Group {
            if let o = model.outcome {
                scanned(o)
            } else {
                NoScanView(model: model, message: "스캔 결과가 없습니다. 먼저 스캔을 시작하세요.")
            }
        }
        .navigationTitle("탐색")
    }

    // MARK: - 골격

    private func scanned(_ o: ScanOutcome) -> some View {
        GeometryReader { geo in
            content(o, width: geo.size.width)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            GlassEffectContainer(spacing: Theme.panelSpacing) {
                pathBar(o)
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        }
        .inspector(isPresented: $showInspector) {
            DetailPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 440)
        }
        .searchable(text: $query, placement: .toolbar, prompt: Text("이름 검색"))
        .searchFocused($searchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Label("상세 패널", systemImage: "sidebar.right")
                }
                .help(showInspector ? "상세 패널 숨기기" : "상세 패널 보기")
            }
        }
        .onAppear { if !model.selection.isEmpty { showInspector = true } }
        .onChange(of: model.selection.isEmpty) { old, new in
            if old && !new { showInspector = true }
        }
        .onChange(of: model.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, f in model.isSearchFocused = f }
        .onDisappear { model.isSearchFocused = false }
        // 검색·칩으로 숨겨진 행은 선택에서 제거한다 (합계·정리·Return 대상은 보이는 행만).
        .onChange(of: visibleRows.map(\.path)) { _, paths in pruneHiddenSelection(visible: Set(paths)) }
        .onChange(of: model.focusPath) { _, _ in
            query = ""
            hover.chartHoverPath = nil
            hover.rowHoverPath = nil
        }
        .task(id: DiscouragedKey(on: chipDiscouraged, focus: model.focusPath,
                                 count: model.rows.count, first: model.rows.first?.id)) {
            await refreshDiscouraged()
        }
    }

    @ViewBuilder private func content(_ o: ScanOutcome, width: CGFloat) -> some View {
        let compact = width < Self.compactWidth
        let parent = max(o.node(at: model.focusPath)?.allocatedSize ?? 0, 1)
        let palette = SunburstPaletteCache.palette(for: model.arcs)
        let colors = Dictionary(model.arcs.filter { $0.depth == 1 && !$0.isOther }.map { ($0.path, palette.color(for: $0, scheme: scheme)) },
                                uniquingKeysWith: { a, _ in a })
        if compact {
            VStack(spacing: 0) {
                SunburstView(model: model, hover: hover)
                    .frame(height: 220)
                listColumn(parent: parent, colors: colors)
            }
        } else {
            let sunburstW = min(max(width * 0.36, 260), 440)
            HStack(spacing: 0) {
                SunburstView(model: model, hover: hover)
                    .frame(width: sunburstW)
                    .frame(maxHeight: .infinity)
                listColumn(parent: parent, colors: colors)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func listColumn(parent: Int64, colors: [String: Color]) -> some View {
        VStack(spacing: 0) {
            controlBar
            if let c = truncationCaption {
                Text(c).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }
            rowList(parent: parent, colors: colors)
                .opacity(model.rowsMatchFocus ? 1 : Theme.Opacity.stale)
                .allowsHitTesting(model.rowsMatchFocus)
        }
    }

    // MARK: - 경로바 (떠 있는 유리 캡슐)

    private func pathBar(_ o: ScanOutcome) -> some View {
        let crumbs = o.breadcrumb(for: model.focusPath)
        let size = o.node(at: model.focusPath).map { Fmt.bytes($0.allocatedSize) } ?? ""
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { model.focusUp() } label: {
                    Label("상위 폴더", systemImage: "arrow.up").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .disabled(o.parentPath(of: model.focusPath) == nil)
                .help("상위 폴더 (⌘↑)")
                PathCrumbs(crumbs: crumbs) { model.focus($0) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Text(size).monospacedDigit()
                    .accessibilityLabel("현재 폴더 크기 \(size)")
                Button { model.rescan() } label: {
                    Label("재스캔", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("재스캔 (⌘R)")
                .disabled(!model.canStartScan)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
            .fixedSize()
            .layoutPriority(1)
        }
    }

    // MARK: - 정렬·필터

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { sortPicker; chips; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 6) { sortPicker; chips }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sortPicker: some View {
        Picker("정렬", selection: Binding(get: { sortChoice }, set: { setSortChoice($0) })) {
            ForEach(ExploreSortChoice.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
        .accessibilityLabel("정렬")
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $chipInUse) { Label("사용 중", systemImage: "lock.fill") }
            Toggle(isOn: $chipDiscouraged) { Label("정리 비권장", systemImage: "exclamationmark.octagon") }
            Toggle(isOn: $chipOrphan) { Label("설치되지 않은 앱 추정", systemImage: "questionmark.folder") }
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private func setSortChoice(_ c: ExploreSortChoice) {
        sortChoice = c
        switch c {
        case .size, .name: if model.sort != .size { model.setSort(.size) }
        case .modified: if model.sort != .modified { model.setSort(.modified) }
        }
    }

    private var filtersActive: Bool { chipInUse || chipDiscouraged || chipOrphan }

    private var visibleRows: [NodeRow] {
        var r = model.rows.filter { !$0.isOmittedSummary }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { r = r.filter { $0.name.localizedStandardContains(q) } }
        if filtersActive {
            r = r.filter { row in
                (chipInUse && !row.inUseBy.isEmpty)
                    || (chipOrphan && row.attribution.isOrphanSuspect)
                    || (chipDiscouraged && discouragedPaths.contains(row.path))
            }
        }
        if sortChoice == .name {
            r.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if q.isEmpty, !filtersActive, let s = model.rows.first(where: \.isOmittedSummary) { r.append(s) }
        return r
    }

    private struct DiscouragedKey: Hashable {
        let on: Bool, focus: String, count: Int, first: String?
    }

    private func refreshDiscouraged() async {
        guard chipDiscouraged, let o = model.outcome else { discouragedPaths = []; return }
        let paths = model.rows.filter { !$0.isOmittedSummary }.map(\.path)
        let found = await Task.detached { Set(paths.filter { o.cleanupAvailability(forPath: $0).isDiscouraged }) }.value
        guard !Task.isCancelled else { return }
        discouragedPaths = found
    }

    // MARK: - 목록

    private func rowList(parent: Int64, colors: [String: Color]) -> some View {
        let rows = visibleRows
        return List(selection: Binding(get: { model.selection }, set: { model.setSelection($0) })) {
            ForEach(rows) { row in
                if row.isOmittedSummary {
                    OmittedSummaryRow(row: row, truncated: truncatedCount != nil) { model.revealInFinder(model.focusPath) }
                        .selectionDisabled()
                } else {
                    NodeRowView(row: row,
                                fraction: Double(row.size) / Double(parent),
                                barColor: colors[row.path] ?? Color.secondary,
                                hover: hover,
                                onOpen: { model.focus(row.path) })
                        .tag(row.path)
                        .onHover { inside in
                            if inside { hover.rowHoverPath = row.path }
                            else if hover.rowHoverPath == row.path { hover.rowHoverPath = nil }
                        }
                }
            }
        }
        .overlay {
            if rows.isEmpty, !model.rows.isEmpty {
                ContentUnavailableView("일치하는 항목이 없습니다", systemImage: "magnifyingglass",
                                       description: Text("검색어나 필터를 바꿔 보세요" + (truncationCaption.map { "\n\($0)" } ?? "")))
            }
        }
        .contextMenu(forSelectionType: String.self) { items in
            rowMenu(items)
        } primaryAction: { items in
            if model.rowsMatchFocus, items.count == 1, let p = items.first, isDirectory(p) { model.focus(p) }
        }
        .onKeyPress(.return) {
            if model.rowsMatchFocus, model.selection.count == 1, let p = model.selection.first, isDirectory(p) {
                model.focus(p)
                return .handled
            }
            return .ignored
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
    }

    private func pruneHiddenSelection(visible: Set<String>) {
        let kept = model.selection.intersection(visible)
        if kept != model.selection { model.setSelection(kept) }
    }

    private func isDirectory(_ path: String) -> Bool {
        model.rows.first { $0.path == path && !$0.isOmittedSummary }?.isDirectory ?? false
    }

    @ViewBuilder private func rowMenu(_ items: Set<String>) -> some View {
        if !items.isEmpty {
            Button("Finder에서 보기") { ExploreActions.revealInFinder(Array(items)) }
            Button("경로 복사") { ExploreActions.copyPaths(Array(items)) }
            if items.count == 1, let p = items.first, isDirectory(p) {
                Button("폴더 열기") { model.focus(p) }
            }
            Divider()
            Button("정리…") { model.startCleanupForSelection() }
                .disabled(model.selection != items || !model.canCleanupSelection)
        }
    }

    // MARK: - 선택 요약 (떠 있는 유리)

    private func cleanupDisabledReason(count n: Int) -> String {
        if n == 0 { return "항목을 선택하세요" }
        if model.isBusy { return "스캔 중에는 정리할 수 없습니다" }
        if model.cleanupFlow != nil || model.isExecutingCleanup { return "정리가 진행 중입니다" }
        return model.selectionCleanup.reason ?? "정리할 수 없습니다"
    }

    private var selectionBar: some View {
        let n = model.selection.count
        let summary = n == 0 ? "선택 없음" : "선택 \(Fmt.count(n))개 · \(Fmt.bytes(ExploreActions.selectionTotal(model)))"
        let reason: String? = model.canCleanupSelection ? nil : cleanupDisabledReason(count: n)
        return GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(summary).monospacedDigit()
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .glassEffect(.regular, in: Capsule())
                        .accessibilityLabel(summary)
                    Button("정리…") { model.startCleanupForSelection() }
                        .buttonStyle(.glass)
                        .disabled(!model.canCleanupSelection)
                        .help(reason ?? "선택 항목 정리 (⌘⌫)")
                        .accessibilityHint(reason ?? "선택한 항목을 정리합니다")
                }
                if let reason, n > 0 {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).padding(.horizontal, 14)
                }
            }
        }
        .padding(8)
    }
}

// MARK: - 경로 구성요소 (중간 생략)

/// 전체 → 앞 1 + … + 뒤 3 → 앞 1 + … + 마지막 순으로 폭에 맞는 첫 변형을 쓴다. 마지막 컴포넌트는 항상 보인다.
private struct PathCrumbs: View {
    let crumbs: [(name: String, path: String)]
    let onSelect: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            variant(tail: crumbs.count, truncateLast: false)
            variant(tail: 3, truncateLast: false)
            variant(tail: 1, truncateLast: true)
        }
    }

    private func variant(tail: Int, truncateLast: Bool) -> some View {
        let keepTail = min(tail, max(crumbs.count - 1, 0))
        let hiddenRange = 1..<max(crumbs.count - keepTail, 1)
        let hidden = crumbs.count > 1 ? Array(crumbs[hiddenRange]) : []
        let shown: [(name: String, path: String)] = {
            guard crumbs.count > 1 else { return crumbs }
            let head = [crumbs[0]]
            return head + Array(crumbs[(crumbs.count - keepTail)...])
        }()
        return HStack(spacing: 4) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                if i > 0 {
                    if i == 1, !hidden.isEmpty {
                        separator
                        Menu {
                            ForEach(Array(hidden.enumerated()), id: \.offset) { _, h in
                                Button(h.name) { onSelect(h.path) }
                            }
                        } label: { Text("…") }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("생략된 상위 폴더")
                    }
                    separator
                }
                crumb(c, isLast: i == shown.count - 1 && crumbs.count > 1, truncate: truncateLast && i == shown.count - 1)
            }
        }
    }

    private var separator: some View {
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func crumb(_ c: (name: String, path: String), isLast: Bool, truncate: Bool) -> some View {
        if isLast || crumbs.count == 1 {
            Text(c.name).fontWeight(.semibold).lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: !truncate, vertical: false)
                .accessibilityLabel("현재 폴더 \(c.name)")
        } else {
            Button(c.name) { onSelect(c.path) }
                .buttonStyle(.plain)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - 행

struct NodeRowView: View {
    let row: NodeRow
    let fraction: Double
    let barColor: Color
    var hover: ExploreHover
    let onOpen: () -> Void

    var body: some View {
        let highlighted = hover.highlightsRow(row.path)
        HStack(spacing: 10) {
            IconProvider.image(for: row.attribution, isDirectory: row.isDirectory)
                .resizable().scaledToFit().frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if !row.inUseBy.isEmpty {
                        Badge(text: "사용 중", systemImage: "lock.fill", color: Theme.review)
                            .help(row.inUseBy.joined(separator: ", "))
                    }
                    if row.isDataless {
                        Image(systemName: "icloud").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("iCloud 전용")
                            .help("iCloud 전용(로컬 0)")
                    }
                }
                AttributionLine(attribution: row.attribution)
                ProportionBar(fraction: fraction, color: barColor)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.bytes(row.size)).monospacedDigit()
                Text(Fmt.date(row.modified)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(Color.accentColor.opacity(highlighted ? Theme.Opacity.rowHover : 0), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAction(named: "폴더 열기") { if row.isDirectory { onOpen() } }
    }

    private var accessibilitySummary: String {
        var parts = [row.name, row.isDirectory ? "폴더" : "파일", Fmt.bytes(row.size),
                     "상위의 \(percentText(fraction))"]
        parts.append(row.attribution.isOrphanSuspect ? "설치되지 않은 앱 추정" : "소속 앱 \(row.attribution.appName)")
        parts.append("수정일 \(Fmt.date(row.modified))")
        if !row.inUseBy.isEmpty { parts.append("사용 중: \(row.inUseBy.joined(separator: ", "))") }
        if row.isDataless { parts.append("iCloud 전용") }
        return parts.joined(separator: ", ")
    }
}

/// 상위 200개 제한으로 빠진 작은 파일 요약 행: 앱에 표시하지 않음 + Finder 열기.
struct OmittedSummaryRow: View {
    let row: NodeRow
    /// 표시 한도(자식 5000 초과)로 잘린 폴더의 나머지인가 (작은 파일 요약과 구분).
    var truncated = false
    let onReveal: () -> Void

    private var caption: String { truncated ? "표시 한도를 넘은 나머지 항목" : "앱에 표시하지 않는 작은 파일" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ellipsis.rectangle").font(.title3).foregroundStyle(.secondary)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Button("Finder에서 보기", action: onReveal)
                    .buttonStyle(.link).font(.caption)
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(row.size)).monospacedDigit()
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(Fmt.bytes(row.size)), \(caption)")
        .accessibilityAction(named: "Finder에서 보기") { onReveal() }
    }
}

struct AttributionLine: View {
    let attribution: Attribution

    var body: some View {
        HStack(spacing: 6) {
            if attribution.isOrphanSuspect {
                NoticeLabel(text: "설치되지 않은 앱 추정", systemImage: "questionmark.circle.fill",
                            color: Theme.review, secondary: true)
            } else {
                Text(attribution.appName).font(.caption).foregroundStyle(.secondary)
            }
            ConfidenceBadge(confidence: attribution.confidence)
        }
    }
}
