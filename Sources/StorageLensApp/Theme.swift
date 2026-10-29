import SwiftUI
import StorageCore

// MARK: - 용어집 (design-6) — 모든 화면 문구는 아래 표를 따른다
//
// | 개념                         | 표준 용어                      | 쓰지 않는 말                         |
// |------------------------------|--------------------------------|--------------------------------------|
// | 데이터를 만든 앱             | 소속 앱                        | 귀속, 프로그램                       |
// | 소속 앱 판단 이유            | 소속 앱 판단 근거              | 귀속 근거                            |
// | 앱이 삭제된 뒤 남은 데이터   | 설치되지 않은 앱 추정          | 고아 추정, 삭제된 앱의 데이터로 추정 |
// | 정리 위험도                  | 안전 / 검토 필요 / 정리 비권장 | 비권장(단독), 위험                   |
// | 앱이 파일을 쓰고 있음        | 사용 중                        | 점유, 잠금                           |
// | 앱이 실행되고 있음           | 실행 중                        |                                      |
// | 정리 방법                    | 휴지통으로 이동 / 도구 실행 / iCloud 로컬 사본 내리기 | 삭제, 제거 |
// | 정리 후 크기 갱신            | 재스캔                         | 다시 스캔(툴팁 제외)                 |
// | 정리 기록                    | 정리 기록                      | 저널                                 |
// | 규칙·카탈로그 파일           | 앱 구성 파일                   | 리소스, 카탈로그(사용자 문구)        |
// | 정리 정보 영역(상세 패널)    | 정리 안내                      | 카탈로그                             |
// | 개수                         | Fmt.count(n) + "개"            | 직접 보간(\(items.count))            |
// 개발자용 문구(빌드 스크립트 이름, 버전 표기 "v2" 등)는 사용자 화면에 노출하지 않는다.

/// 디자인 토큰 (GUIDELINES §3). 하드코딩 cornerRadius·opacity·상태 색은 여기서만 정의한다.
enum Theme {
    /// 간격 4/8/12/16/24.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// 떠 있는 패널 내부 패딩.
    static let panelPadding: CGFloat = 12
    /// 떠 있는 패널 사이 간격 (GlassEffectContainer spacing).
    static let panelSpacing: CGFloat = 8

    /// 모서리 반경 토큰 (임의 값 난립 금지).
    enum Radius {
        static let panel: CGFloat = 16   // 떠 있는 유리 패널(배너·진행 카드)
        static let card: CGFloat = 12    // 작은 유리 카드(툴팁)
        static let small: CGFloat = 8    // 행 호버 하이라이트
        static let bar: CGFloat = 5      // 용량 막대 클립
    }

    /// 떠 있는 패널 모양 (창 모서리와 동심에 가까운 연속 곡률 둥근 사각형).
    static var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.panel, style: .continuous) }
    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card, style: .continuous) }

    /// 불투명도 토큰.
    enum Opacity {
        static let badgeFill = 0.15      // 배지 배경
        static let glassTint = 0.15      // 유리 위 심각도 tint
        static let rowHover = 0.10       // 행 호버 하이라이트 (GUIDELINES §5: 10% 이하)
        static let dim = 0.35            // 선버스트 비강조 조각
        static let track = 0.35          // 용량 막대 빈 구간
        static let stale = 0.5           // 새 폴더 로딩 중 이전 목록·차트 흐림
    }

    /// 선버스트 조각 이름 글자색 (조각 색 휘도로 선택, 대비 4.5:1 이상 목표).
    enum ChartLabel {
        static let onLight = Color.black.opacity(0.85)   // 밝은 조각 위
        static let onDark = Color.white.opacity(0.95)    // 어두운 조각 위
        /// 상대 휘도(WCAG)가 이 값보다 크면 검정 글자.
        static let darkTextThreshold = 0.18

        /// HSB 색의 상대 휘도 (sRGB 선형화).
        static func luminance(hue: Double, saturation: Double, brightness: Double) -> Double {
            let h = (hue - hue.rounded(.down)) * 6
            let c = brightness * saturation
            let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
            let m = brightness - c
            let (r, g, b): (Double, Double, Double) = switch Int(h) {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r + m) + 0.7152 * lin(g + m) + 0.0722 * lin(b + m)
        }
    }

    /// 상태 색: 아이콘·점·막대에만 쓰고 본문 글씨에는 쓰지 않는다.
    static let safe = Color.green
    static let review = Color.orange
    static let discouraged = Color.red
    static let info = Color.blue
    static let neutral = Color.gray

    /// 배너·알림 심각도.
    enum Severity {
        case info, success, warning, error

        var color: Color {
            switch self {
            case .info: Theme.info
            case .success: Theme.safe
            case .warning: Theme.review
            case .error: Theme.discouraged
            }
        }

        var defaultIcon: String {
            switch self {
            case .info: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "exclamationmark.octagon.fill"
            }
        }
    }
}

extension Safety {
    /// 배지·접근성용 한글 이름.
    var tagLabel: String {
        switch self {
        case .safe: "안전"
        case .review: "검토 필요"
        case .discouraged: "정리 비권장"
        }
    }

    /// 안전도 정렬 키 (안전 < 검토 < 비권장).
    var sortRank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .discouraged: 2
        }
    }

    var color: Color {
        switch self {
        case .safe: Theme.safe
        case .review: Theme.review
        case .discouraged: Theme.discouraged
        }
    }

    /// 색에 의존하지 않도록 의미 아이콘을 함께 쓴다 (체크/경고/금지).
    var icon: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .review: "exclamationmark.triangle.fill"
        case .discouraged: "nosign"
        }
    }
}
