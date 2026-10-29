import SwiftUI
import StorageCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.canProceed {
                MainView(model: model)
            } else {
                OnboardingView(model: model)
            }
        }
        .onAppear { AppModel.active = model }
        // 시스템 설정에서 돌아오면 권한을 자동으로 다시 확인한다.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.recheckFullDiskAccess()
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: AppModel

    private var statusText: String {
        switch model.fdaStatus {
        case .granted: "전체 디스크 접근: 허용됨"
        case .denied: "전체 디스크 접근: 허용되지 않음"
        case .undetermined: "전체 디스크 접근: 확인 불가 (권한이 필요한 폴더를 확인하지 못했습니다)"
        }
    }

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(systemName: "externaldrive.badge.checkmark").font(.largeTitle).imageScale(.large)
                .accessibilityHidden(true)
            Text("전체 디스크 접근 권한").font(.title2.bold())
            Text(statusText)
            Text("모든 폴더의 크기를 정확히 계산하려면 시스템 설정에서 StorageLens에 전체 디스크 접근을 허용해야 합니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("허용 후 앱을 재시작해야 적용됩니다")
                .font(.callout.bold())
            Text("설정에서 돌아오면 자동으로 다시 확인합니다.")
                .font(.callout).foregroundStyle(.secondary)
            if let n = model.onboardingNotice {
                NoticeLabel(text: n, systemImage: "exclamationmark.triangle.fill", color: Theme.review, font: .callout)
                    .multilineTextAlignment(.center)
            }
            GlassEffectContainer(spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Button("시스템 설정 열기") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.glassProminent)
                    Button("다시 확인") { model.recheckFromOnboarding() }
                        .buttonStyle(.glass)
                    Button("앱 다시 시작") { model.restartApp() }
                        .buttonStyle(.glass)
                        .disabled(!model.canRestartApp)
                        .help(model.canRestartApp ? "허용한 권한을 적용하려면 앱을 다시 시작합니다" : "정리가 진행 중이라 다시 시작할 수 없습니다")
                    Button("부분 스캔으로 계속") { model.continuePartial = true }
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
