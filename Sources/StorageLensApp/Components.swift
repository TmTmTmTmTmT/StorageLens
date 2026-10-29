import SwiftUI
import StorageCore

// 공용 컴포넌트 (design-10). 배지·배너·안내 행은 화면마다 따로 만들지 말고 여기 것을 쓴다.
// 규칙: 글자는 항상 .primary/.secondary, 색은 아이콘·점·막대에만 (GUIDELINES §3).

/// 색 점(또는 아이콘) + 시맨틱 색 글자. 배경 없는 한 줄 상태 표시.
struct DotLabel: View {
    let text: String
    var systemImage: String?
    let color: Color

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            marker
            Text(text).foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marker: some View {
        if let systemImage {
            Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
        } else {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
        }
    }
}

/// 캡슐 배지 (콘텐츠 요소, 유리 아님). 아이콘이 없으면 색 점.
struct Badge: View {
    let text: String
    var systemImage: String?
    let color: Color

    var body: some View {
        DotLabel(text: text, systemImage: systemImage, color: color)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(Theme.Opacity.badgeFill), in: Capsule())
    }
}

/// 안전도 태그: 의미 아이콘(체크/경고/금지) + 한글 이름 (a11y-i18n-3).
struct SafetyTag: View {
    let safety: Safety
    var body: some View {
        Badge(text: safety.tagLabel, systemImage: safety.icon, color: safety.color)
    }
}

/// 소속 앱 판단 신뢰도 배지.
struct ConfidenceBadge: View {
    let confidence: Confidence
    var body: some View {
        switch confidence {
        case .exact: Badge(text: "정확", systemImage: "checkmark.circle.fill", color: Theme.safe)
        case .inferred: Badge(text: "추정", systemImage: "questionmark.circle.fill", color: Theme.review)
        case .unknown: Badge(text: "알 수 없음", systemImage: "circle.dotted", color: Theme.neutral)
        }
    }
}

/// 아이콘(상태 색) + 시맨틱 색 본문 한 줄 안내.
struct NoticeLabel: View {
    let text: String
    let systemImage: String
    let color: Color
    var secondary = false
    var font: Font = .caption

    var body: some View {
        Label {
            Text(text).foregroundStyle(secondary ? .secondary : .primary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(font)
    }
}

/// 상위 폴더 대비 비율 막대 (콘텐츠 요소, 유리 아님).
struct ProportionBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        Capsule().fill(.quaternary)
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(color)
                        .frame(width: max(3, g.size.width * min(max(fraction, 0), 1)))
                }
            }
            .accessibilityHidden(true)
    }
}

/// 콘텐츠 위에 떠 있는 유리 배너 카드. 심각도는 아이콘 색 + 옅은 tint, 버튼은 `.glass`.
/// 여러 개는 호출하는 쪽에서 `GlassEffectContainer` 세로 스택으로 묶는다 (유리 안 유리 방지).
struct FloatingBanner<Actions: View>: View {
    let severity: Theme.Severity
    let text: String
    var systemImage: String?
    @ViewBuilder var actions: () -> Actions

    init(_ severity: Theme.Severity, text: String, systemImage: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.severity = severity
        self.text = text
        self.systemImage = systemImage
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage ?? severity.defaultIcon)
                .foregroundStyle(severity.color)
                .accessibilityHidden(true)
            Text(text).font(.callout).foregroundStyle(.primary).textSelection(.enabled)
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: Theme.Space.s) { actions() }.buttonStyle(.glass)
        }
        .padding(Theme.panelPadding)
        .glassEffect(.regular.tint(severity.color.opacity(Theme.Opacity.glassTint)), in: Theme.panelShape)
    }
}

/// 정리 후 재스캔 권장 카드.
struct RescanBanner: View {
    @Bindable var model: AppModel
    var body: some View {
        FloatingBanner(.warning, text: "정리가 실행되었습니다. 크기를 갱신하려면 재스캔을 권장합니다.",
                       systemImage: "arrow.clockwise.circle.fill") {
            Button("재스캔") { model.rescan() }.disabled(!model.canStartScan)
        }
    }
}
