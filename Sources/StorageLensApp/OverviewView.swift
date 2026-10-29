import SwiftUI
import StorageCore

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                // 핵심 요약(용량)이 첫 화면 최상단에 온다 (design-7).
                if let v = model.volume { VolumeBar(volume: v) }
                ScanControlBar(model: model)
                if model.resourcesMissing {
                    NoticeLabel(text: "앱 구성 파일(규칙·정리 안내 목록)을 찾지 못했습니다. 앱을 다시 설치해 주세요. 소속 앱·카테고리가 비어 보일 수 있습니다.",
                                systemImage: "exclamationmark.triangle.fill", color: Theme.review, font: .callout)
                }
                if let o = model.outcome {
                    trashSection(o)
                    icloudSection
                    categorySection(o)
                    changeSection(o)
                    if let hf = o.huggingFace { HuggingFaceSection(hf: hf) }
                } else {
                    Text("스캔을 시작하면 카테고리·증감·휴지통·Hugging Face 정보가 여기에 표시됩니다.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("개요")
    }

    @ViewBuilder private func trashSection(_ o: ScanOutcome) -> some View {
        OverviewSection("휴지통") {
            HStack {
                Image(systemName: "trash").foregroundStyle(.secondary).accessibilityHidden(true)
                if let t = o.trashBytes {
                    Text("\(Fmt.bytes(t)) — 비우기 전까지 공간이 확보되지 않습니다")
                } else {
                    Text("휴지통 크기를 읽을 수 없습니다 (전체 디스크 접근 권한 필요)")
                }
                Spacer()
                Button("Finder에서 휴지통 열기") { model.openTrashInFinder() }
            }
        }
    }

    @ViewBuilder private var icloudSection: some View {
        OverviewSection("iCloud") {
            HStack {
                Image(systemName: "icloud").foregroundStyle(.secondary).accessibilityHidden(true)
                if let inv = model.icloud {
                    Text("로컬 사본 \(Fmt.bytes(inv.totalLocalBytes))")
                    if inv.totalCloudOnly > 0 {
                        Text("· 클라우드 전용 \(Fmt.count(inv.totalCloudOnly))개").foregroundStyle(.secondary)
                    }
                } else {
                    Text("로컬 사본 계산 중…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("iCloud 화면 열기") { model.navigate(to: .icloud) }
            }
        }
    }

    /// 카탈로그 항목의 첫 경로 패턴에서 와일드카드 앞까지를 대표 경로로 쓴다. 패턴이 없으면 nil.
    private func representativePath(_ id: String, _ o: ScanOutcome) -> String? {
        guard let pattern = o.catalog.entry(id: id)?.pathPatterns.first else { return nil }
        var segs: [String] = []
        for seg in pattern.split(separator: "/", omittingEmptySubsequences: true) {
            if seg.contains("*") { break }
            segs.append(String(seg))
        }
        guard !segs.isEmpty else { return nil }
        if segs[0] == "~" {
            segs.removeFirst()
            return (FileManager.default.homeDirectoryForCurrentUser.path as NSString)
                .appendingPathComponent(segs.joined(separator: "/"))
        }
        return "/" + segs.joined(separator: "/")
    }

    @ViewBuilder private func categorySection(_ o: ScanOutcome) -> some View {
        OverviewSection("카테고리별 합계") {
            if let cats = model.overviewCategories {
                // iCloud 로컬 사본은 별도 섹션에 표시하고 다른 카테고리 합계에 섞지 않는다 (PLAN §16.4).
                let total = max(cats.rows.reduce(Int64(0)) { $0 + $1.size }, 1)
                ForEach(cats.rows) { row in
                    let target = representativePath(row.id, o)
                    NavRow(path: target, help: "탐색에서 열기", model: model) {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            HStack {
                                Text(row.title)
                                if let s = row.safety { SafetyTag(safety: s) }
                                Spacer()
                                Text(Fmt.bytes(row.size)).monospacedDigit()
                            }
                            // 전체 합계 대비 비율 막대 (콘텐츠 요소, 유리 아님).
                            ProportionBar(fraction: Double(row.size) / Double(total),
                                          color: row.safety?.color ?? Theme.info)
                        }
                    }
                }
                if cats.rows.isEmpty { Text("표시할 카테고리가 없습니다.").foregroundStyle(.secondary) }
                ForEach(cats.virtualItems) { v in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(v.entry.title); SafetyTag(safety: v.entry.safety) }
                            if v.availability.enabled {
                                Text(v.entry.note).font(.caption).foregroundStyle(.secondary)
                            } else {
                                NoticeLabel(text: v.availability.reason ?? "실행할 수 없습니다",
                                            systemImage: "exclamationmark.triangle.fill", color: Theme.review,
                                            secondary: true)
                            }
                        }
                        Spacer()
                        Button("실행…") { model.beginVirtualCleanup(v.entry) }
                            .disabled(!v.availability.enabled || model.isBusy)
                    }
                }
            } else {
                ProgressView("카테고리를 계산하는 중…").controlSize(.small)
            }
        }
    }

    @ViewBuilder private func changeSection(_ o: ScanOutcome) -> some View {
        OverviewSection("지난 스캔 대비 증감 (상위 10)") {
            if let prev = o.previous {
                Text("비교 기준: \(Fmt.date(prev.scannedAt)) 스캔").font(.caption).foregroundStyle(.secondary)
                ForEach(o.topChanges, id: \.path) { c in
                    NavRow(path: c.path, help: "탐색에서 열기", model: model) {
                        Text(c.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        // 증감 방향은 색뿐 아니라 화살표 아이콘과 접근성 라벨(증가/감소)로도 전달한다.
                        Image(systemName: c.delta > 0 ? "arrow.up" : "arrow.down")
                            .foregroundStyle(c.delta > 0 ? Theme.discouraged : Theme.safe)
                            .accessibilityLabel(c.delta > 0 ? "증가" : "감소")
                        Text(Fmt.signedBytes(c.delta)).monospacedDigit()
                    }
                }
                if o.topChanges.isEmpty { Text("변화 없음").foregroundStyle(.secondary) }
            } else {
                Text("같은 루트의 이전 스캔이 없습니다. 다음 스캔부터 비교됩니다.").foregroundStyle(.secondary)
            }
        }
    }
}

/// 개요 섹션: 제목(headline) + 본문. 모든 섹션이 같은 위계를 쓴다 (design-7).
private struct OverviewSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// 클릭하면 탐색 화면에서 경로를 여는 행. path가 nil이면 일반 행(비활성). 호버 시 화살표 어포던스.
private struct NavRow<Content: View>: View {
    let path: String?
    let help: String
    @Bindable var model: AppModel
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        if let path {
            Button { model.reveal(path: path) } label: {
                HStack { content()
                    Image(systemName: "chevron.right").font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0.25)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        } else {
            HStack { content() }
        }
    }
}

struct VolumeBar: View {
    let volume: VolumeInfo

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("저장 공간").font(.headline)
            GeometryReader { geo in
                let t = Double(max(volume.total, 1))
                HStack(spacing: 1) {
                    Rectangle().fill(Theme.info).frame(width: geo.size.width * Double(volume.used) / t)
                    Rectangle().fill(Theme.review).frame(width: geo.size.width * Double(volume.purgeable) / t)
                    Rectangle().fill(Theme.neutral.opacity(Theme.Opacity.track))
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.bar))
            }
            .frame(height: 18)
            HStack(spacing: Theme.Space.l) {
                legend(Theme.info, "사용", volume.used)
                legend(Theme.review, "정리 가능", volume.purgeable)
                legend(Theme.neutral, "사용 가능", volume.available)
                Spacer()
                Text("전체 \(Fmt.bytes(volume.total))").font(.caption).foregroundStyle(.secondary)
            }
        }
        // 막대·범례는 장식이므로 숨기고 요약 한 줄을 읽어 준다 (a11y-i18n-3).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("저장 공간: 사용 \(Fmt.bytes(volume.used)), 정리 가능 \(Fmt.bytes(volume.purgeable)), 사용 가능 \(Fmt.bytes(volume.available)), 전체 \(Fmt.bytes(volume.total))")
    }

    private func legend(_ c: Color, _ title: String, _ n: Int64) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text("\(title) \(Fmt.bytes(n))").font(.callout)
        }
    }
}

struct HuggingFaceSection: View {
    let hf: HuggingFaceOverview

    var body: some View {
        OverviewSection("Hugging Face") {
            Text(hf.note).font(.callout).foregroundStyle(.secondary)
            if hf.blobsExists {
                HStack {
                    Text("공유 저장소 hub/blobs")
                    Spacer()
                    Text(hf.blobsBytes.map(Fmt.bytes) ?? "—").monospacedDigit()
                }
            }
            Text("모델별 실제 크기는 공유 저장소 구조 때문에 표시하지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            hfList("모델", hf.items.filter { $0.kind == .model })
            hfList("데이터셋", hf.items.filter { $0.kind == .dataset })
        }
    }

    @ViewBuilder private func hfList(_ title: String, _ items: [HuggingFaceInventory.Item]) -> some View {
        if !items.isEmpty {
            Text("\(title) \(Fmt.count(items.count))개").font(.subheadline.bold()).padding(.top, 4)
            ForEach(items, id: \.path) { it in
                HStack {
                    Text(it.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("수정 \(Fmt.date(it.modified))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
