import SwiftUI
import StorageCore

/// iCloud 전용 화면 (PLAN §16.4): 요약, 컨테이너 목록, 하위 폴더 + 업로드 대기 + 로컬 사본 내리기.
struct ICloudView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.outcome == nil {
                NoScanView(model: model, message: "스캔 결과가 없습니다. 먼저 스캔을 시작하면 iCloud 로컬 사본이 표시됩니다.")
            } else if let inv = model.icloud {
                if inv.containers.isEmpty {
                    Text("iCloud 컨테이너를 찾지 못했습니다. iCloud Drive를 사용하지 않거나, 홈 폴더가 스캔 범위에 없습니다.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(inv)
                }
            } else {
                ProgressView("iCloud 정보를 계산하는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("iCloud")
    }

    private func content(_ inv: ICloudInventory) -> some View {
        VStack(spacing: 0) {
            summary(inv)
            HStack(spacing: 0) {
                containerList(inv)
                    .frame(width: min(max(model.windowSize.width * 0.36, 300), 460))
                Divider()
                containerDetail(inv)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func summary(_ inv: ICloudInventory) -> some View {
        HStack(spacing: 24) {
            stat("로컬 사용량", Fmt.bytes(inv.totalLocalBytes))
            stat("클라우드 전용 파일", "\(Fmt.count(inv.totalCloudOnly))개")
            stat("전체 파일", "\(Fmt.count(inv.totalFileCount))개")
            Spacer()
            Text("로컬 사본을 내려도 iCloud의 원본은 유지됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }

    private func containerList(_ inv: ICloudInventory) -> some View {
        List(selection: Binding(get: { model.selectedContainerPath },
                                set: { model.selectContainer($0) })) {
            ForEach(inv.containers) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.displayName).lineLimit(1)
                        Spacer()
                        Text(Fmt.bytes(c.localBytes)).monospacedDigit()
                    }
                    Text("클라우드 전용 \(Fmt.count(c.cloudOnlyFileCount))개 / 전체 \(Fmt.count(c.fileCount))개")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(c.path)
            }
        }
    }

    @ViewBuilder private func containerDetail(_ inv: ICloudInventory) -> some View {
        if let path = model.selectedContainerPath, let c = inv.containers.first(where: { $0.path == path }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.displayName).font(.headline)
                        Text(c.folderName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Button("로컬 사본 내리기…") { model.beginCleanup(paths: [c.path]) }
                            .disabled(evictDisabled)
                            .accessibilityLabel("로컬 사본 내리기, \(c.displayName)")
                        if let hint = evictHint {
                            Text(hint).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                pendingRow(c)
                if model.pendingState == .running, model.subfolders.isEmpty {
                    ProgressView().controlSize(.small).padding()
                }
                if model.subfolders.isEmpty, model.pendingState != .running {
                    Text("하위 폴더가 없습니다.").foregroundStyle(.secondary).padding()
                }
                List(model.subfolders) { f in
                    HStack {
                        Image(systemName: "folder")
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.bytes(f.localBytes)).monospacedDigit().foregroundStyle(.secondary)
                        Button("로컬 사본 내리기…") { model.beginCleanup(paths: [f.path]) }
                            .disabled(evictDisabled)
                            .help(evictHint ?? "이 폴더의 로컬 사본을 내립니다")
                            .accessibilityLabel("로컬 사본 내리기, \(f.name)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(f.name), \(Fmt.bytes(f.localBytes))")
                }
            }
        } else {
            Text("왼쪽에서 컨테이너를 선택하세요.").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 업로드 대기 조회 중에는 내리기를 막는다 (usability-8).
    private var evictDisabled: Bool { model.isBusy || model.pendingState == .running }

    private var evictHint: String? {
        model.pendingState == .running ? "업로드 대기 파일 조회가 끝나면 내릴 수 있습니다" : nil
    }

    @ViewBuilder private func pendingRow(_ c: ICloudContainer) -> some View {
        HStack(spacing: 8) {
            switch model.pendingState {
            case .idle:
                Text("업로드 대기 조회를 하지 않았거나 취소했습니다.").font(.callout).foregroundStyle(.secondary)
                Button("다시 조회") { model.selectContainer(c.path) }.buttonStyle(.glass)
            case .running:
                ProgressView().controlSize(.small)
                Text("업로드 대기 파일 조회 중…").font(.callout)
                Button("취소") { model.cancelPendingCheck() }.buttonStyle(.glass)
            case .done(let pending, let checked, let truncated):
                Image(systemName: pending > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(pending > 0 ? Theme.review : Theme.safe)
                Text(pending > 0
                     ? "이 컨테이너 전체에 업로드 대기 \(Fmt.count(pending))개 — 폴더별로 구분하지 않으며, 내리면 해당 파일은 실패하거나 건너뛸 수 있습니다"
                     : "이 컨테이너 전체에 업로드 대기 파일 없음")
                    .font(.callout)
                Text("(확인한 파일 \(Fmt.count(checked))개" + (truncated ? " · 일부만 확인" : "") + ")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.bottom, 8)
    }
}
