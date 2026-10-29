# StorageLens — UI 가이드라인: Liquid Glass (v1.2, 2026-10-29)

사용자 지시: 디자인은 Liquid Glass 표준 적용. 배포 대상 macOS 26.0 (Package.swift) → 가용성 분기 불필요.
SDK에서 확인된 API (SwiftUICore/SwiftUI 인터페이스): `glassEffect(_:in:)`, `Glass.regular/.clear/.identity`, `.tint(_:)`, `.interactive()`, `GlassEffectContainer(spacing:)`, `glassEffectID(_:in:)`, `glassEffectUnion(id:namespace:)`, `ConcentricRectangle`, `ButtonStyle .glass / .glassProminent`, `backgroundExtensionEffect()`, `scrollEdgeEffectStyle(_:for:)`, `ToolbarSpacer`, `sharedBackgroundVisibility(_:)`, `inspector(isPresented:content:)`, `navigationSubtitle(_:)`.
쓰기 전에 의심되는 시그니처는 SDK swiftinterface를 grep해 확인할 것(`xcrun --show-sdk-path` 아래 SwiftUICore.framework/…/arm64e-apple-macos.swiftinterface). 존재하지 않는 API 추측 사용 금지.

## 1. 원칙
1. **두 층 분리**: 유리(glass)는 콘텐츠 위에 떠 있는 *내비게이션·컨트롤 층*에만. 콘텐츠 층(목록, 표, 선버스트, 개요 수치, 시트 본문)은 유리 금지.
2. **시스템 우선**: NavigationSplitView 사이드바, `.toolbar`, `.searchable`, `.inspector`, `.sheet`, 메뉴, 표준 버튼은 시스템이 자동으로 Liquid Glass를 그린다. 그 뒤에 커스텀 배경(`.background(.bar)`, `.regularMaterial`, 단색 띠, 구분선)을 깔지 말 것 — 제거 대상.
3. **유리 위 유리 금지**: 유리 요소 안에 또 유리 금지. 가까운 유리 요소 여러 개는 `GlassEffectContainer`로 묶어 하나로 합쳐지게.
4. **틴트 절제**: 화면당 주 동작 1개만 `.glassProminent`(강조색). 나머지 버튼 `.glass` 또는 기본. 상태 색(경고·오류)은 유리 `.tint(color.opacity…)`를 옅게 쓰거나 아이콘 색으로만. 큰 면적 원색 배경 금지.
5. **모양**: 컨트롤은 캡슐/원, 떠 있는 패널은 `ConcentricRectangle` 또는 창 모서리와 동심인 둥근 사각형. 임의 cornerRadius 값 난립 금지(토큰화: Theme).
6. **스크롤 가장자리**: 툴바 아래 구분선 대신 시스템 scroll edge effect. 필요 시 `.scrollEdgeEffectStyle(.soft, for: .top)`.
7. **접근성**: 시스템 유리는 투명도 줄이기·대비 증가를 자동 처리. 커스텀 `glassEffect` 위 텍스트는 `.primary/.secondary` 시맨틱 색만, 작은 색 글씨 금지. 라이트·다크·투명도 줄이기 3가지 모두에서 읽혀야 함.
8. **애니메이션**: 유리 요소 등장·변형은 `glassEffectID` + `@Namespace`로 모핑, 과한 커스텀 애니메이션 금지.

## 2. 화면별 적용
| 영역 | 적용 |
|---|---|
| 창 골격 (MainView) | NavigationSplitView 기본 사이드바(List `.sidebar`), 사이드바·디테일에 커스텀 배경 없음. 화면 제목 `navigationTitle`, 범위·스캔 시각은 `navigationSubtitle`. |
| 툴바 | 스캔/재스캔·취소를 한 그룹, `ToolbarSpacer`로 분리 후 정리(주 동작이면 `.glassProminent`, 비활성 시 기본). 탐색 화면 검색은 `.searchable`(툴바 배치, ⌘F 연결). |
| 진행·배너 | 상단 띠(`.background(.bar)`/단색) 대신 콘텐츠 위 떠 있는 유리 카드: `.glassEffect(.regular, in: ConcentricRectangle 또는 RoundedRectangle)`, 여러 개면 `GlassEffectContainer`로 세로 스택. 심각도는 아이콘 색 + 옅은 tint. 닫기·다시 시도 버튼 `.glass`. |
| 탐색 경로바 | 떠 있는 유리 캡슐(경로 버튼들) — 또는 툴바 principal. 우측 크기·재스캔은 같은 컨테이너 안 별도 캡슐. |
| 상세 패널 | 좁은 폭 오버레이 대신 `.inspector(isPresented:)` 사용(시스템 유리·크기 조절). 넓은 폭에서도 inspector로 통일 가능하면 통일. 토글은 툴바 버튼. |
| 선버스트 | 차트 자체는 콘텐츠(유리 금지). 중앙 버튼은 원형 `.buttonStyle(.glass)`. 호버 툴팁은 작은 유리 카드(`.glassEffect(in: RoundedRectangle)`). |
| 목록·표 (탐색·앱별·정리 기록·iCloud) | 시스템 List/Table 그대로, 행 배경 커스텀 금지. 비율 막대·배지는 콘텐츠 요소(작은 캡슐, 시맨틱 색, 유리 아님). |
| 앱별 하단 동작 바 | 떠 있는 유리 바: `GlassEffectContainer` 안에 선택 요약 텍스트 + `.glass` 보조 버튼 + `.glassProminent` 정리 버튼. |
| 개요 | 카드 배경 `.quaternary` 둥근 사각형 대신 GroupBox 또는 여백·섹션 제목 위계. 용량 막대·카테고리 막대는 콘텐츠. |
| 정리 시트 | 시스템 시트 그대로(커스텀 presentationBackground 금지). 하단 버튼: 취소 기본, 실행은 `.glassProminent` + `role: .destructive`(휴지통/도구 실행). 경고 박스는 옅은 tint 유리 대신 아이콘+텍스트 행(시트 본문은 콘텐츠 층). |
| 온보딩 (RootView) | 중앙 콘텐츠, 주 버튼 "시스템 설정 열기" `.glassProminent`, 보조 `.glass`. |

## 3. 토큰 (Theme.swift, C1에서 생성 — B단계는 아래 값을 직접 쓰고 C1이 토큰으로 치환)
- 간격 4/8/12/16/24, 떠 있는 패널 내부 패딩 12, 패널 간 간격 8.
- 배지: caption 굵기 medium, 캡슐, 배경 `color.opacity(0.15)` + 글자 `color`는 대비 부족 → 글자는 `.primary`, 앞에 색 점/아이콘.
- 상태 색: 안전 green, 확인 필요 orange, 비권장 red, 정보 blue — 아이콘·점에만.

## 4. 금지 목록 (검토 시 grep)
`.background(.bar)`, `.regularMaterial`/`.ultraThinMaterial` 직접 사용, 툴바·사이드바 뒤 커스텀 배경, 유리 안 유리, 콘텐츠 행에 glassEffect, 화면당 `.glassProminent` 2개 이상, 하드코딩 색 글씨(`.foregroundStyle(.orange)` 등을 본문 텍스트에).

## 5. Opus 결정 (B2 확인 요청, 2026-10-29)
- 행 호버 하이라이트(옅은 accent 배경)는 허용: 일시적 상호작용 피드백이며 정적 행 배경이 아님. 선택 하이라이트와 구분되게 10% 이하 유지.
- 탐색 레이아웃 기준: 콘텐츠 폭 600 미만이면 선버스트를 목록 위, 이상이면 좌우. 상세는 `.inspector`. (PLAN §16.5의 "1100 기준 3열/2열" 대체)
- 인스펙터·시트·팝오버 등 시스템이 유리로 그리는 표면 안의 컨트롤은 기본 버튼 스타일(유리 위 유리 금지). `.glass`는 콘텐츠 위에 직접 떠 있는 커스텀 유리 카드 안에서만.
- RescanBanner는 창 상단 FloatingStack 한 곳에서만 표시(C1 결정 승인). "사용 중" 주황, "실행 중" 초록.
