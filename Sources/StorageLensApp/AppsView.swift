import SwiftUI
import StorageCore

/// 앱별 데이터 화면 (PLAN §16.3): 좌측 앱 목록, 우측 항목 테이블.
struct AppsView: View {
    @Bindable var model: AppModel
    @State private var selectedID: String?
    @State private var search = ""
    @State private var systemExpanded = false
    /// 그룹 id -> 체크된 항목 경로. 그룹을 처음 열 때 safe 항목만 체크한다.
    /// 그룹 id -> 체크된 항목 경로 (경로 기준이라 재스캔 후에도 유지). 그룹을 처음 열 때 safe 항목만 체크한다.
    @State private var checked: [String: Set<String>] = [:]
    @State private var sortOrder = [KeyPathComparator(\AppDataItem.size, order: .reverse)]
    /// 체크된 항목의 정리 가용성 (경로 기준, 비동기 계산 — F11-6).
    @State private var availability: [String: CleanupAvailability] = [:]

    private struct AvailabilityKey: Hashable {
        let group: String?
        let missing: [String]
    }

    /// 선택된 그룹에서 체크됐지만 아직 가용성을 모르는 경로.
    private var missingAvailability: [String] {
        guard let g = selectedGroup else { return [] }
        let set = checked[g.id] ?? defaultChecked(g)
        return g.items.map(\.path).filter { set.contains($0) && availability[$0] == nil }
    }

    private func refreshAvailability() async {
        guard let o = model.outcome, let gid = selectedID else { return }
        let paths = missingAvailability
        guard !paths.isEmpty else { return }
        let found = await Task.detached { () -> [String: CleanupAvailability]? in
            var d: [String: CleanupAvailability] = [:]
            for p in paths {
                if Task.isCancelled { return nil }
                d[p] = o.cleanupAvailability(forPath: p)
            }
            return d
        }.value
        guard !Task.isCancelled, let found, model.outcome === o else { return }
        availability.merge(found) { _, new in new }
        // 정리 불가로 판정된 항목은 체크에서 뺀다.
        if let g = model.appGroups.first(where: { $0.id == gid }) {
            let cur = checked[gid] ?? defaultChecked(g)
            let kept = cur.filter { availability[$0]?.enabled != false }
            if kept != cur { checked[gid] = kept }
        }
    }

    var body: some View {
        Group {
            if model.outcome == nil {
                NoScanView(model: model, message: "스캔 결과가 없습니다. 먼저 스캔을 시작하면 앱별 데이터가 표시됩니다.")
            } else if model.appGroups.isEmpty {
                Text(model.appGroupsLoading ? "앱별 데이터를 계산하는 중…" : "앱별로 묶을 데이터가 없습니다. 홈 폴더를 포함해 스캔했는지 확인하세요.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    groupList
                        .frame(width: min(max(model.windowSize.width * 0.28, 240), 360))
                    Divider()
                    detail
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("앱별")
        .onAppear {
            // 스캔 완료 시 이미 계산됨 (perf-9): 비어 있고 계산 중이 아닐 때만 다시 계산.
            if model.outcome != nil, model.appGroups.isEmpty, !model.appGroupsLoading { model.refreshAppGroups() }
            ensureChecked(selectedID)
        }
        .onChange(of: selectedID) { _, id in ensureChecked(id) }
        .onChange(of: model.appGroups) { _, _ in availability = [:]; ensureChecked(selectedID) }
        // 정리 시트가 닫히면 사용 중 상태 등이 바뀌었을 수 있어 다시 판정한다.
        .onChange(of: model.cleanupFlow == nil) { _, _ in availability = [:] }
        .task(id: AvailabilityKey(group: selectedID, missing: missingAvailability)) { await refreshAvailability() }
    }

    // MARK: 좌측 앱 목록

    private func filtered() -> [AppDataGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.appGroups }
        return model.appGroups.filter {
            $0.appName.localizedCaseInsensitiveContains(q) || ($0.bundleID?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var groupList: some View {
        let all = filtered()
        let apps = all.filter { !$0.isSystem }
        let system = all.filter(\.isSystem)
        return VStack(spacing: 0) {
            TextField("앱 검색", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: $selectedID) {
                ForEach(apps) { g in
                    GroupRow(group: g).tag(g.id)
                }
                if !system.isEmpty {
                    DisclosureGroup(isExpanded: $systemExpanded) {
                        ForEach(system) { g in
                            GroupRow(group: g).tag(g.id)
                        }
                    } label: {
                        Label("macOS 시스템", systemImage: "gearshape")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if apps.isEmpty, system.isEmpty {
                Text("검색 결과가 없습니다.").font(.callout).foregroundStyle(.secondary).padding()
            }
        }
    }

    // MARK: 우측 항목 테이블

    private var selectedGroup: AppDataGroup? {
        guard let id = selectedID else { return nil }
        return model.appGroups.first { $0.id == id }
    }

    @ViewBuilder private var detail: some View {
        if let g = selectedGroup {
            let set = checked[g.id] ?? defaultChecked(g)
            VStack(alignment: .leading, spacing: 0) {
                header(g)
                if g.isRunning {
                    NoticeLabel(text: "앱 종료 후 정리 권장 — 실행 중인 앱의 데이터를 지우면 문제가 생길 수 있습니다.",
                                systemImage: "exclamationmark.triangle.fill", color: Theme.review, font: .callout)
                        .padding(.horizontal, 10).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                selectionTools(g, set)
                itemTable(g, set)
            }
            .safeAreaInset(edge: .bottom) { actionBar(g, set) }
        } else {
            Text("왼쪽에서 앱을 선택하세요.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ g: AppDataGroup) -> some View {
        HStack(spacing: 10) {
            IconProvider.image(for: g.iconSource, isDirectory: true)
                .resizable().scaledToFit().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(g.appName).font(.headline)
                    if g.isVendorShared { Badge(text: "제조사 공용", color: Theme.info) }
                }
                if let b = g.bundleID { Text(b).font(.caption).foregroundStyle(.secondary) }
                if g.hasOmittedFiles {
                    Label("일부 파일 생략(\(Fmt.bytes(g.omittedBytes)))", systemImage: "ellipsis.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("스캔 제한으로 일부 파일이 목록에서 생략되었고 합계에만 반영되었습니다.")
                }
            }
            Spacer()
            Text(Fmt.bytes(g.totalBytes)).font(.title3.monospacedDigit())
        }
        .padding(10)
    }

    /// 머리글 영역: 전체 선택 체크박스 + 빠른 선택.
    private func selectionTools(_ g: AppDataGroup, _ set: Set<String>) -> some View {
        let usable = g.items.filter { availability[$0.path]?.enabled != false }
        let allOn = !usable.isEmpty && usable.allSatisfy { set.contains($0.path) }
        return HStack(spacing: 12) {
            Toggle("전체 선택", isOn: Binding(
                get: { allOn },
                set: { on in checked[g.id] = on ? Set(usable.map(\.path)) : [] }))
            Button("캐시만 선택") {
                checked[g.id] = Set(usable.filter { $0.kind.isCache }.map(\.path))
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func itemTable(_ g: AppDataGroup, _ set: Set<String>) -> some View {
        let rows = g.items.sorted(using: sortOrder)
        return Table(rows, sortOrder: $sortOrder) {
            TableColumn("") { item in
                Toggle(isOn: Binding(
                    get: { (checked[g.id] ?? set).contains(item.path) },
                    set: { on in
                        var cur = checked[g.id] ?? set
                        if on { cur.insert(item.path) } else { cur.remove(item.path) }
                        checked[g.id] = cur
                    })) {
                    Text("\(item.name), \(item.kind.label), \((item.safety ?? .review).tagLabel)"
                         + (blockedReason(item).map { ", 정리 불가: \($0)" } ?? ""))
                }
                .labelsHidden()
                .disabled(blockedReason(item) != nil)
            }
            .width(28)
            TableColumn("위치", value: \.kind.label) { item in Text(item.kind.label).lineLimit(1) }
                .width(min: 70, ideal: 100)
            TableColumn("이름", value: \.name) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.name).lineLimit(1).truncationMode(.middle).help(item.path)
                        if !item.inUseBy.isEmpty {
                            Badge(text: "사용 중", systemImage: "lock.fill", color: Theme.review)
                                .help(item.inUseBy.joined(separator: ", "))
                        }
                    }
                    if let r = blockedReason(item) {
                        Text("정리 불가: \(r)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            TableColumn("크기", value: \.size) { item in Text(Fmt.bytes(item.size)).monospacedDigit() }
                .width(min: 70, ideal: 90)
            TableColumn("수정일", value: \.modified) { item in Text(Fmt.date(item.modified)).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110)
            TableColumn("안전도", value: \.safetyRank) { item in SafetyTag(safety: item.safety ?? .review) }
                .width(min: 80, ideal: 100)
        }
    }

    /// 떠 있는 유리 동작 바 (GUIDELINES §2).
    private func actionBar(_ g: AppDataGroup, _ set: Set<String>) -> some View {
        // 정리 불가로 판정된 항목은 선택에서 제외한다.
        let selectedItems = g.items.filter { set.contains($0.path) && blockedReason($0) == nil }
        let checking = selectedItems.contains { availability[$0.path] == nil }
        let total = selectedItems.reduce(Int64(0)) { $0 + $1.size }
        let discouraged = selectedItems.filter { $0.safety == .discouraged }.count
        let disabledReason: String? = model.isBusy ? "스캔 또는 정리가 진행 중이라 정리할 수 없습니다."
            : (selectedItems.isEmpty ? "정리할 항목을 먼저 선택하세요."
               : (checking ? "정리 가능 여부를 확인하는 중…" : nil))
        return VStack(alignment: .trailing, spacing: 4) {
            if let r = disabledReason {
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
            GlassEffectContainer(spacing: Theme.panelSpacing) {
                HStack(spacing: Theme.Space.s) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("선택 \(Fmt.count(selectedItems.count))개 · \(Fmt.bytes(total))").font(.callout.monospacedDigit())
                        if discouraged > 0 {
                            NoticeLabel(text: "정리 비권장 \(Fmt.count(discouraged))개 포함",
                                        systemImage: "exclamationmark.octagon.fill", color: Theme.discouraged)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                    Button("선택 해제") { checked[g.id] = [] }
                        .buttonStyle(.glass)
                        .disabled(selectedItems.isEmpty)
                    Button("선택 항목 정리…") { model.beginCleanup(paths: selectedItems.map(\.path)) }
                        .buttonStyle(.glassProminent)
                        .disabled(selectedItems.isEmpty || model.isBusy || checking)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 정리 불가 사유 (가용성 판정이 끝났고 불가일 때만).
    private func blockedReason(_ item: AppDataItem) -> String? {
        guard let a = availability[item.path], !a.enabled else { return nil }
        return a.reason ?? "정리할 수 없는 항목입니다"
    }

    /// 기본 체크 = 안전(safe) 항목만.
    private func defaultChecked(_ g: AppDataGroup) -> Set<String> {
        Set(g.items.filter { $0.safety == .safe }.map(\.path))
    }

    private func ensureChecked(_ id: String?) {
        guard let id, checked[id] == nil, let g = model.appGroups.first(where: { $0.id == id }) else { return }
        checked[id] = defaultChecked(g)
    }
}

private extension AppDataItem {
    /// 안전도 열 정렬 키 (안전 정보 없음 = 검토).
    var safetyRank: Int { (safety ?? .review).sortRank }
}

private struct GroupRow: View {
    let group: AppDataGroup

    var body: some View {
        HStack(spacing: 8) {
            IconProvider.image(for: group.iconSource, isDirectory: true)
                .resizable().scaledToFit().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.appName).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 4) {
                    if group.isRunning { Badge(text: "실행 중", systemImage: "play.circle.fill", color: Theme.safe) }
                    if group.isOrphanSuspect { Badge(text: "설치되지 않은 앱 추정", systemImage: "questionmark.circle.fill", color: Theme.review) }
                    if group.isVendorShared { Badge(text: "제조사 공용", color: Theme.info) }
                }
            }
            Spacer(minLength: 4)
            Text(Fmt.bytes(group.totalBytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
