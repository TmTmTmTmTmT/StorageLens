import SwiftUI
import StorageCore

/// 정리 시트 (PLAN §3-5): 미리보기 -> 확인 -> 실행 -> 결과.
struct CleanupSheet: View {
    @Bindable var model: AppModel
    @Bindable var flow: CleanupFlow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("정리: \(flow.title)").font(.title3.bold())
            Divider()
            switch flow.phase {
            case .idle, .closed:
                EmptyView()
            case .planning:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView("사용 중인 파일 조회 및 계획 수립 중…")
                    progressLines
                    HStack {
                        Spacer()
                        Button("취소", role: .cancel) { model.cancelCleanupPlanning() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            case .preview:
                if let plan = flow.plan { preview(plan) }
            case .executing:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView("정리 실행 중… 창을 닫지 마세요")
                    progressLines
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            case .done:
                if let r = flow.result { resultView(r) }
            }
        }
        .padding(20)
        .interactiveDismissDisabled(flow.machine.isDismissBlocked)
        .frame(minWidth: 520, idealWidth: idealWidth, maxWidth: 900,
               minHeight: 360, idealHeight: idealHeight, maxHeight: 820)
    }

    /// 부모 창 크기 비례: 폭 60% (520...900), 높이 75% (360...760).
    private var idealWidth: CGFloat { min(max(model.windowSize.width * 0.6, 520), 900) }
    private var idealHeight: CGFloat { min(max(model.windowSize.height * 0.75, 360), 760) }

    // MARK: 진행 표시

    @ViewBuilder private var progressLines: some View {
        if let p = flow.progress {
            Text("항목 \(Fmt.count(min(p.itemIndex + 1, p.itemCount)))/\(Fmt.count(p.itemCount)) · 확인한 항목 \(Fmt.count(p.processedCount))개")
                .font(.callout.monospacedDigit())
            Text(p.currentPath).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    // MARK: 미리보기

    /// 아이콘만 색을 쓰고 글자는 시맨틱 색을 쓰는 안내 행.
    private func note(_ text: String, _ icon: String, _ color: Color, font: Font = .caption) -> some View {
        NoticeLabel(text: text, systemImage: icon, color: color, secondary: true, font: font)
    }

    private func methodSummary(_ plan: CleanupPlan) -> String {
        var names: [String] = []
        for it in plan.items {
            let n = methodName(it.method)
            if !names.contains(n) { names.append(n) }
        }
        return names.joined(separator: ", ")
    }

    private func executeTitle(_ plan: CleanupPlan, total: Int64) -> String {
        let methods = Set(plan.items.map(\.method))
        let n = Fmt.count(plan.items.count)
        if methods == [.trash] { return "휴지통으로 이동 (\(n)개, \(Fmt.bytes(total)))" }
        if methods == [.command] { return "명령 실행 (\(n)개)" }
        if methods == [.icloudEvict] { return "로컬 사본 내리기 (\(n)개, \(Fmt.bytes(total)))" }
        return "정리 실행 (\(n)개, \(Fmt.bytes(total)))"
    }

    @ViewBuilder private func preview(_ plan: CleanupPlan) -> some View {
        let total = plan.items.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let discouraged = plan.items.filter(\.isDiscouraged)
        // 상단 고정 요약 (스크롤 밖)
        if !plan.items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Fmt.count(plan.items.count))개 항목 · 합계 \(Fmt.bytes(total))")
                    .font(.headline.monospacedDigit())
                Text("방법: \(methodSummary(plan))").font(.callout).foregroundStyle(.secondary)
                if !discouraged.isEmpty {
                    note("정리 비권장 \(Fmt.count(discouraged.count))개 포함", "exclamationmark.octagon.fill", Theme.discouraged, font: .callout)
                }
                if plan.unmeasuredCount > 0 {
                    note("\(Fmt.count(plan.unmeasuredCount))개 항목은 크기에 포함되지 않음", "questionmark.circle", Theme.review)
                }
                if plan.items.contains(where: { $0.method == .icloudEvict }) { pendingNote }
            }
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(plan.items, id: \.path) { item in
                    itemRow(item)
                    Divider()
                }
                if !plan.rejected.isEmpty {
                    DisclosureGroup("거부된 항목 \(Fmt.count(plan.rejected.count))개 (실행되지 않음)") {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(plan.rejected, id: \.path) { r in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.path).font(.callout).lineLimit(1).truncationMode(.middle)
                                    note(r.reason, "xmark.circle.fill", Theme.discouraged)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 8)
                }
                if plan.items.isEmpty { Text("정리할 수 있는 항목이 없습니다.").foregroundStyle(.secondary).padding(.vertical, 8) }
            }
        }
        .frame(maxHeight: .infinity)
        if !discouraged.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                note("앱 설정·데이터·개인 파일이 사라질 수 있습니다. 휴지통에서 되돌릴 수 있습니다.",
                     "exclamationmark.octagon.fill", Theme.discouraged, font: .callout)
                Toggle("비권장 항목임을 이해했습니다", isOn: $flow.acknowledged)
            }
        }
        HStack {
            Spacer()
            if plan.items.isEmpty {
                Button("닫기") { model.closeCleanup() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(.glassProminent)
            } else {
                let destructive = plan.items.contains { $0.method != .icloudEvict }
                Button("취소", role: .cancel) { model.closeCleanup() }.keyboardShortcut(.cancelAction)
                Button(executeTitle(plan, total: total), role: destructive ? .destructive : nil) {
                    model.confirmCleanup(flow)
                }
                .buttonStyle(.glassProminent)
                .disabled(!discouraged.isEmpty && !flow.acknowledged)
            }
        }
    }

    /// iCloud 내리기: 업로드 대기 조회 결과 안내 (usability-8).
    @ViewBuilder private var pendingNote: some View {
        switch model.pendingState {
        case .running:
            note("업로드 대기 파일 조회 중입니다. 끝나기 전에 내리면 업로드 전 파일이 실패할 수 있습니다.", "clock", Theme.review)
        case .done(let pending, _, _) where pending > 0:
            note("이 컨테이너에 업로드 대기 \(Fmt.count(pending))개가 있습니다. 해당 파일은 실패하거나 건너뛸 수 있습니다.",
                 "exclamationmark.triangle.fill", Theme.review)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private func itemRow(_ item: CleanupPlanItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.isVirtual ? (item.title ?? item.path) : item.path)
                    .lineLimit(2).truncationMode(.middle)
                Spacer()
                if !item.isVirtual { Text(Fmt.bytes(item.sizeBytes)).monospacedDigit() }
            }
            if item.isDiscouraged {
                note("정리 비권장", "exclamationmark.octagon.fill", Theme.discouraged)
            }
            Text("방법: \(methodName(item.method))" +
                 (item.isVirtual || item.method == .command
                  ? " · \(item.toolPath ?? "") \(item.commandArguments.joined(separator: " "))" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if item.method == .command, let tp = item.toolPath, flow.nonStandardToolPaths.contains(tp) {
                note("표준 위치가 아닌 경로의 도구입니다: \(tp)", "exclamationmark.triangle.fill", Theme.review)
            }
            if item.method == .icloudEvict {
                note("업로드되지 않은 파일은 건너뜁니다", "icloud.slash", Theme.neutral)
            }
            if item.unmeasuredCount > 0 {
                note("\(Fmt.count(item.unmeasuredCount))개 항목은 크기에 포함되지 않음", "questionmark.circle", Theme.review)
            }
            ForEach(item.warnings, id: \.self) {
                note($0, "exclamationmark.triangle.fill", item.isDiscouraged ? Theme.discouraged : Theme.review)
            }
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 결과

    @ViewBuilder private func resultView(_ r: CleanupResult) -> some View {
        if r.planExpired {
            note("계획이 만료되었습니다 (10분). 다시 계획을 만들어 주세요.", "clock.badge.exclamationmark", Theme.review, font: .body)
            HStack {
                Spacer()
                Button("닫기") { model.closeCleanup() }
                Button("다시 계획") { model.replan(flow) }.buttonStyle(.glassProminent)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(r.outcomes, id: \.path) { o in outcomeRow(o) }
                    let cancelled = r.outcomes.filter { $0.status == .skipped && $0.reason == "취소됨" }.count
                    if cancelled > 0 {
                        note("취소되어 \(Fmt.count(cancelled))개 항목을 건너뛰었습니다", "xmark.circle", Theme.review, font: .callout)
                    }
                    if r.outcomes.contains(where: { $0.method == .trash && $0.status == .succeeded }) {
                        Label(Cleaner.trashNotice, systemImage: "trash").font(.callout.bold())
                            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let p = flow.plan, !p.rejected.isEmpty {
                        Text("거부된 항목 \(Fmt.count(p.rejected.count))개는 실행되지 않았습니다.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Text("정리 후 크기를 갱신하려면 재스캔을 권장합니다.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { model.closeCleanup() }
                Button("닫고 재스캔") {
                    model.closeCleanup()
                    if model.cleanupFlow == nil { model.rescan() }
                }
                .buttonStyle(.glassProminent)
                .disabled(model.isBusy)
            }
        }
    }

    @ViewBuilder private func outcomeRow(_ o: CleanupItemOutcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(o.path.hasPrefix("virtual:") ? flow.title : o.path)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                DotLabel(text: statusText(o.status), color: statusColor(o.status))
            }
            if let why = o.reason { Text(why).font(.caption).foregroundStyle(.secondary) }
            if o.method == .command, o.freedBytes > 0 {
                Text("확보: \(Fmt.bytes(o.freedBytes))").font(.caption)
            }
            if o.notUploadedCount > 0 {
                note("업로드되지 않아 건너뛴 파일 \(Fmt.count(o.notUploadedCount))개", "icloud.slash", Theme.review)
            }
            if o.unmeasuredCount > 0 {
                note("\(Fmt.count(o.unmeasuredCount))개 항목은 크기에 포함되지 않음", "questionmark.circle", Theme.neutral)
            }
            ForEach(Array(o.skippedFiles.enumerated()), id: \.offset) { _, f in
                note("건너뜀: \(f.path) — \(f.reason)", "arrow.uturn.forward.circle", Theme.review, font: .caption2)
                    .lineLimit(1).truncationMode(.middle)
            }
            if o.omittedSkippedCount > 0 {
                note("건너뜀 외 \(Fmt.count(o.omittedSkippedCount))건", "arrow.uturn.forward.circle", Theme.review, font: .caption2)
            }
            ForEach(Array(o.failures.enumerated()), id: \.offset) { _, f in
                note("\(f.path) — \(f.reason)", "xmark.circle.fill", Theme.review, font: .caption2)
                    .lineLimit(1).truncationMode(.middle)
            }
            if o.omittedFailureCount > 0 {
                note("실패 외 \(Fmt.count(o.omittedFailureCount))건", "xmark.circle.fill", Theme.review, font: .caption2)
            }
            if let je = o.journalError { note(je, "exclamationmark.octagon.fill", Theme.discouraged) }
        }
    }

    private func methodName(_ m: CleanupMethod) -> String {
        switch m {
        case .trash: "휴지통으로 이동"
        case .command: "도구 실행"
        case .icloudEvict: "iCloud 로컬 사본 내리기 (클라우드 원본 유지)"
        case .none: "없음"
        }
    }

    private func statusText(_ s: CleanupStatus) -> String {
        switch s {
        case .succeeded: "성공"
        case .partial: "일부 성공"
        case .skipped: "건너뜀"
        case .failed: "실패"
        }
    }

    private func statusColor(_ s: CleanupStatus) -> Color {
        switch s {
        case .succeeded: Theme.safe
        case .partial, .skipped: Theme.review
        case .failed: Theme.discouraged
        }
    }
}
