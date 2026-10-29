import SwiftUI
import StorageCore

/// 탐색 화면 인스펙터 내용: 없음 / 단일 / 다중 선택 요약.
struct DetailPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if model.selection.count > 1 {
                    multiSummary
                } else if model.selection.isEmpty {
                    ContentUnavailableView("선택한 항목이 없습니다", systemImage: "sidebar.right",
                                           description: Text("목록이나 차트에서 항목을 선택하면 상세 정보가 표시됩니다"))
                } else if let d = model.detail {
                    single(d)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(Theme.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 다중 선택

    private struct BlockedReason: Identifiable {
        let reason: String
        let count: Int
        var id: String { reason }
    }

    private func blockedReasons(_ blocked: [CleanupAvailability]) -> [BlockedReason] {
        var counts: [String: Int] = [:]
        for a in blocked where !a.isOutsideHome { counts[a.reason ?? "정리할 수 없습니다", default: 0] += 1 }
        var out: [BlockedReason] = []
        for (k, v) in counts { out.append(BlockedReason(reason: k, count: v)) }
        out.sort { $0.count != $1.count ? $0.count > $1.count : $0.reason < $1.reason }
        return out
    }

    @ViewBuilder private var multiSummary: some View {
        let n: Int = model.selection.count
        let avs: [CleanupAvailability] = model.selection.compactMap { model.availabilities[$0] }
        summaryCard(n: n, avs: avs)

        HStack(spacing: Theme.Space.s) {
            Button("정리…") { model.startCleanupForSelection() }
                .buttonStyle(.bordered)
                .disabled(!model.canCleanupSelection)
            Button("Finder에서 보기") { ExploreActions.revealInFinder(Array(model.selection)) }
                .buttonStyle(.bordered)
        }
    }

    private func summaryCard(n: Int, avs: [CleanupAvailability]) -> some View {
        let total: Int64 = ExploreActions.selectionTotal(model)
        let blocked: [CleanupAvailability] = avs.filter { !$0.enabled }
        let outside: Int = blocked.filter { $0.isOutsideHome }.count
        let enabled: Int = avs.count - blocked.count
        let reasons = blockedReasons(blocked)
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                field("선택", "\(Fmt.count(n))개")
                field("합계 크기", Fmt.bytes(total))
                if avs.count < n {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("정리 가능 여부 확인 중…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    field("정리 가능", "\(Fmt.count(enabled))개 / \(Fmt.count(n))개")
                    if outside > 0 {
                        NoticeLabel(text: "\(Fmt.count(outside))개: \(CleanupAvailability.outsideHomeReason)",
                                    systemImage: "lock.fill", color: Theme.review)
                    }
                    ForEach(reasons) { r in
                        NoticeLabel(text: "\(Fmt.count(r.count))개: \(r.reason)", systemImage: "exclamationmark.triangle.fill",
                                    color: Theme.review)
                    }
                    if !blocked.isEmpty {
                        Text("정리할 수 없는 항목이 포함되어 있으면 일괄 정리를 시작할 수 없습니다. 해당 항목을 선택에서 빼 주세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("선택 요약").font(.subheadline.bold())
        }
    }

    // MARK: - 단일 선택

    @ViewBuilder private func single(_ d: NodeDetail) -> some View {
        HStack(spacing: 8) {
            IconProvider.image(for: d.attribution, isDirectory: d.isDirectory)
                .resizable().scaledToFit().frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(d.name).font(.headline).lineLimit(2)
                Text(Fmt.bytes(d.size)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        field("전체 경로", d.path, selectable: true)
        field("수정일", Fmt.date(d.modified))
        if d.isDataless {
            NoticeLabel(text: "iCloud 전용(로컬 0)", systemImage: "icloud", color: Theme.neutral, secondary: true)
        }
        if !d.inUseBy.isEmpty { field("사용 중", d.inUseBy.joined(separator: ", ")) }

        Divider()
        Text("소속 앱").font(.subheadline.bold())
        HStack {
            Text(d.attribution.isOrphanSuspect ? "설치되지 않은 앱 추정" : d.attribution.appName)
            ConfidenceBadge(confidence: d.attribution.confidence)
        }
        if let s = d.attribution.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
        if let b = d.attribution.bundleID { field("번들 ID", b) }
        field("소속 앱 판단 근거", d.attribution.rule)

        if let c = d.catalog {
            Divider()
            Text("정리 안내").font(.subheadline.bold())
            HStack { Text(c.entry.title); SafetyTag(safety: c.entry.safety) }
            if !c.entry.note.isEmpty { Text(c.entry.note).font(.caption).foregroundStyle(.secondary) }
            if let why = c.unavailableReason {
                NoticeLabel(text: why, systemImage: "exclamationmark.triangle.fill", color: Theme.review)
            }
            if c.matchedRoot != d.path { field("정리 단위", c.matchedRoot) }
        }

        Divider()
        Text("다운로드 출처").font(.subheadline.bold())
        if model.originLoading {
            ProgressView().controlSize(.small)
        } else if let o = model.origin {
            if let a = o.agentName { field("다운로드한 앱", a) }
            if let q = o.quarantineDate { field("다운로드 시각", Fmt.date(q)) }
            ForEach(o.whereFroms, id: \.self) { field("URL", $0, selectable: true) }
        } else {
            Text("정보 없음").font(.caption).foregroundStyle(.secondary)
        }

        Divider()
        HStack(spacing: Theme.Space.s) {
            Button("Finder에서 보기") { model.revealInFinder(d.path) }.buttonStyle(.bordered)
            Button("경로 복사") { ExploreActions.copyPaths([d.path]) }.buttonStyle(.bordered)
        }
        detailCleanup(d)
        Text("복제(APFS 클론) 파일은 실제보다 크게 보일 수 있습니다")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func detailCleanup(_ d: NodeDetail) -> some View {
        let av = model.availabilities[d.path]
        VStack(alignment: .leading, spacing: 6) {
            Button("정리…") { model.beginCleanup(paths: [d.path]) }
                .buttonStyle(.bordered)
                .disabled(av?.enabled != true || model.selection.count != 1 || model.isBusy)
            if av == nil {
                NoticeLabel(text: "정리 가능 여부 확인 중…", systemImage: "hourglass", color: Theme.neutral, secondary: true)
            } else if let av, !av.enabled, let r = av.reason {
                NoticeLabel(text: r, systemImage: av.isOutsideHome ? "lock.fill" : "exclamationmark.triangle.fill",
                            color: Theme.review)
                if av.isOutsideHome {
                    Text("시스템 영역은 이 버전에서 정리할 수 없습니다. Finder에서 직접 확인하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if av?.isDiscouraged == true {
                NoticeLabel(text: "정리 비권장 항목입니다. 앱 설정·데이터·개인 파일이 사라질 수 있습니다. 정리 시 확인 체크가 필요하며 휴지통에서 되돌릴 수 있습니다.",
                            systemImage: "exclamationmark.octagon.fill", color: Theme.discouraged)
            } else if av?.safety == .review || (av != nil && av?.safety == nil) {
                Text("검토가 필요한 항목입니다. 하나씩 확인 후 정리하세요.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func field(_ title: String, _ value: String, selectable: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if selectable { Text(value).font(.callout).textSelection(.enabled) }
            else { Text(value).font(.callout) }
        }
    }
}
