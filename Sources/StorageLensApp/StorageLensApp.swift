import SwiftUI
import AppKit
import StorageCore

@main
struct StorageLensApp: App {
    /// 실행 중 종료 시 확인 (AppModel.active 참조).
    @NSApplicationDelegateAdaptor(AppTerminationGuard.self) private var terminationGuard
    @State private var model = AppModel()

    init() {
        // 가장 먼저: iCloud dataless 파일 자동 다운로드 방지.
        disableDatalessMaterialization()
    }

    /// 첫 실행 기본 창 크기: 화면 visibleFrame의 75%×80% (최소 900×600, 최대 1600×1100). 이후는 macOS 창 복원.
    static func defaultWindowSize() -> CGSize {
        let f = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: min(max(f.width * 0.75, 900), 1600),
                      height: min(max(f.height * 0.8, 600), 1100))
    }

    var body: some Scene {
        let size = Self.defaultWindowSize()
        // 모델 하나를 메뉴 명령과 공유하므로 단일 창.
        Window("StorageLens", id: "main") {
            RootView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: size.width, height: size.height)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }
    }
}

/// 메뉴 명령: 스캔 · 보기 · 정리 (usability-1, design-4, a11y-11).
struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandMenu("스캔") {
            Button(model.outcome == nil ? "스캔 시작" : "재스캔") { model.rescan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canStartScan)
            Button("스캔 취소") { model.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.state != .scanning)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                Button(item.title) { model.navigate(to: item) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(!model.canNavigate)
            }
            Divider()
            Button("상위 폴더") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUpCommand)
            Button("검색") { model.searchFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!(model.sidebar == .explore && model.outcome != nil))
        }
        CommandMenu("정리") {
            Button("선택 항목 정리…") { model.startCleanupForSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canCleanupCommand)
        }
    }
}
