# FIX_GUIDE

## F1 — 고아 추정 오탐 (M1-T2, Attributor.isOrphan)
- 오류 원인: §5.2 고아 조건이 같은 제조사의 다른 번들 ID나 접두·접미가 붙은 이름을 걸러내지 못함. 실측 오탐: `com.mathworks.matlabconnector`(설치 앱 `com.mathworks.matlab`, 규칙 5는 2세그먼트에서 중단), `com.infraware.polarisoffice`(설치 앱 `com.infraware.polarisofficeService`), `bugsnag-shared-com.goodsnooze.vivid`(설치 앱 `com.goodsnooze.vivid`).
- 수정 방향: isOrphan에 AND 조건 2개 추가(PLAN §5.2 개정본). ① 설치 앱 중 역DNS 앞 2세그먼트(소문자)가 대상 ID(원본·접두 제거본)의 앞 2세그먼트와 같은 앱이 있으면 고아 아님. ② 대상 폴더 이름(소문자)에 설치 앱 번들 ID(소문자, 점 2개 이상인 것만)가 부분 문자열로 포함되면 고아 아님. 제조사 접두 집합·번들 ID 목록은 init 시 1회 계산.
- 영향 범위: Attributor 고아 판정만. 귀속 결과(appName 등)·규칙 순서 변경 금지.
- 재현/검증: 위 3사례 음성 테스트 추가, 기존 양성 테스트 유지. `SL_ATTR_REPORT=1` 재실행 시 3사례가 목록에서 빠지고 고아 개수 감소.

## F2 — Group Containers 이중 접두 (Attributor.stripGroupPrefix)
- 오류 원인: `UBF8T346G9.group.com.microsoft.shared`에서 팀 ID만 제거되어 `group.com.microsoft.shared`가 남음 → 제조사 접두가 `group.com`이 되어 설치된 Microsoft Office(`com.microsoft.*`)와 매칭 실패, 고아 오탐.
- 수정 방향: §5.2-6 접두 제거를 팀 ID(10자 대문자·숫자 + `.`)와 `group.`이 연속으로 붙은 경우 둘 다 제거(순서 무관, 각 최대 1회). 고아 판정의 strippedID도 이 결과 사용.
- 영향 범위: stripGroupPrefix 및 그 호출부만.
- 재현/검증: `UBF8T346G9.group.com.microsoft.shared` + 설치 앱 `com.microsoft.Word` → 규칙 6으로 귀속(Microsoft 계열, .inferred) 또는 최소 고아 아님 테스트. REPORT 재실행 시 해당 항목이 고아 목록에서 빠짐.

## F4 — 하위에 더 구체적인 카탈로그 패턴이 있을 때 카테고리 합계 누락 (Session/CategoryTotals)
- 오류 원인: 합계 순회가 첫 매칭 노드에서 하위로 내려가지 않음 → `~/Library/Caches/Homebrew`가 `user-caches`(`~/Library/Caches/*`)에 먼저 잡혀 `homebrew`(`…/Homebrew/downloads/*`) 합계가 항상 0. §6.1 "가장 구체적인 패턴 우선"과 불일치.
- 수정 방향: 매칭 노드에서, 카탈로그 패턴 중 그 노드 경로의 **엄격한 하위**를 가리킬 수 있는 패턴(패턴 세그먼트가 노드 경로보다 길고 앞부분이 노드 경로와 매칭)이 있으면 계속 하향. 하위에서 더 구체적 항목에 매칭된 노드 크기는 그 항목에 더하고, 부모 항목 합계에서는 빼서 이중 집계 없음. 그런 패턴이 없으면 기존처럼 중단.
- 영향 범위: CategoryTotals 계산만.
- 재현/검증: SessionTests에 `~/Library/Caches/Homebrew/downloads/a`(100) + `~/Library/Caches/Homebrew/other`(50) 트리 → homebrew 100, user-caches 50. 전체 합계 보존 테스트.

## F5 — Cleaner가 호출자 제공 카탈로그 매칭을 신뢰 (Cleanup/Cleaner.planItem)
- 오류 원인: `CleanupSelection.match`가 nil이면 "카탈로그 밖 → review → trash"로 처리. UI가 match를 빠뜨리면 `never` 경로(`~/Library/Application Support/*`, Containers 등)도 휴지통 이동 가능. 안전 판정이 호출자에 의존.
- 수정 방향: Cleaner init에 `CatalogMatcher`와 귀속 조회 클로저 `(String) -> Attribution?`(고아 판정용, 기본 nil)를 **필수/주입**으로 받는다. 경로 선택이면 Cleaner가 `matcher.match(path:attribution:modified:)`를 직접 계산해 사용하고 `sel.match`는 무시(가상 항목만 `sel.match` 사용, 단 가상 항목도 catalog에 같은 id가 있고 pathPatterns 비어 있는지 Cleaner가 확인). 직접 계산 결과가 never/none이면 거부. execute 재검증 때도 다시 매칭해 never/none이면 skipped. minAgeDays용 modified는 FileSystem.attributes로.
- 영향 범위: Cleaner init·planItem·executeItem, CleanupTests(헬퍼에 matcher 주입). PathSafety 변경 금지.
- 재현/검증: match 없이 `~/Library/Application Support/X` 선택 → rejected("정리 금지 항목"). 호출자가 가짜 safe match를 붙여 never 경로 전달 → 여전히 거부. 고아 귀속(isOrphanSuspect) 클로저 주입 시 orphan 항목으로 허용(review). 기존 24개 테스트 유지.

## F6 — CatalogMatcher 홈과 실제 홈(realpath) 불일치 시 never 판정 누락 (Cleaner)
- 오류 원인: 매처 홈이 realpath와 다르면(예 `/var` vs `/private/var`) 카탈로그 패턴 불일치 → never 경로가 "카탈로그 밖(review)"으로 판정 가능. execute 재검증은 정규화 경로만 매칭.
- 수정 방향(실패 시 닫힘): ① CatalogMatcher에 홈 경로 공개 읽기 프로퍼티 추가(`homePath: String`, 기존 segments 기반). ② Cleaner init에서 `realpath(home)`과 `matcher.homePath`를 비교해 다르면 내부 플래그 설정 → plan()은 모든 선택을 "카탈로그 홈 불일치(안전상 정리 불가)"로 rejected, execute()는 모든 항목 skipped. ③ execute 재검증도 plan과 같이 입력 경로·realpath 경로 둘 다 매칭해 더 엄격한 쪽 사용.
- 영향 범위: Catalog.swift(프로퍼티 추가만), Cleaner.swift, CleanupTests.swift.
- 재현/검증: 매처 홈 `/var/...`, Cleaner 홈 `/private/var/...`(같은 임시 디렉터리) → plan 전부 rejected 테스트. 일치 시 기존 테스트 전부 통과.

## F7 — v1.2 감사 항목 일괄 (PLAN §17)
- 오류 원인: 항목별 `AUDIT_v1.2.md`의 "원인/근거"(file:line 확인됨, 적대적 검증 통과 70건).
- 수정 방향: 항목별 `AUDIT_v1.2.md` "수정 방향" + PLAN §17 "판단 확정(Opus)"이 우선. 충돌 시 §17 우선. 정리 경로 검사는 전부 fail-closed.
- 영향 범위: PLAN §17 표의 작업별 "소유 파일"만 수정. 소유 밖 파일 변경 필요 시 수정 말고 반환.
- 재현/검증: PLAN §17 "검증" 절의 항목별 신규 테스트 + 전체 `swift test` + 서명 빌드. 실제 사용자 데이터 정리 실행 금지(테스트 폴더·임시 디렉터리만).

## F8 — 홈 밖(시스템 영역) 경로의 정리 버튼이 활성 → 시트에서 내부 문구로 거부 (사용자 GUI 확인 A, 2026-10-29)
- 오류 원인: `ScanOutcome.cleanupAvailability(forPath:)`(Session/CleanupSupport.swift)가 홈 밖 경로를 판정하지 않음. `/Library/Application Support/TeamViewer`(root 소유)가 카탈로그 밖 → enabled=true(review) → 시트를 연 뒤에야 PathSafety가 "홈 디렉터리 밖의 경로"로 거부. 시트는 정리할 항목이 0개인데도 "확인" 버튼을 보여 줌. 홈 밖·root 소유 정리는 v2(§10, 권한 헬퍼) 결정 그대로 유지.
- 수정 방향: ① 가용성 판정에서 경로가 세션 홈(realpath 기준, 논리 경로 /System/Volumes/Data 접두 차이 고려) 밖이면 enabled=false, reason "시스템 영역(홈 폴더 밖)은 이 앱에서 정리할 수 없습니다. Finder에서 직접 삭제하세요(관리자 암호 필요)." 와 구분 플래그(`isOutsideHome`) 노출. ② PathSafety의 거부 사유 문구를 같은 사용자 문구로 통일(로직 변경 금지). ③ 정리 시트: 계획 항목이 0개면 실행 버튼 없이 "닫기"만, 거부 사유는 그대로 표시. ④ 상세 패널에 비활성 사유와 "Finder에서 보기"가 보이는지 확인(이미 있으면 유지).
- 영향 범위: Session/CleanupSupport.swift, Cleanup/PathSafety.swift(문구만), StorageLensApp/CleanupSheet.swift(0개일 때 버튼), 테스트. 다중 선택 일괄 정리에서도 홈 밖 항목은 비활성 사유로 걸러짐.
- 재현/검증: 테스트 — 홈 밖 경로 availability enabled=false·isOutsideHome·사유 문구; 홈 안 카탈로그 밖 경로는 기존대로 enabled. GUI — 탐색에서 /Library/Application Support/TeamViewer 선택 시 정리 버튼 비활성+사유, 시트 진입 불가.

## F9 — 단계 B 통합 검증 발견 (2026-10-29, 리뷰+적대 검증 통과분)
- 오류 원인 / 수정 방향 (항목별):
  - F9-1 (medium) 메뉴 ⌘⌫·⌘↑가 검색 필드 편집 중에도 정리 시트 열기·상위 이동으로 가로챔(StorageLensApp.swift 명령 disabled가 검색 포커스 무시). → 검색 필드 포커스 상태를 모델(또는 focusedSceneValue)로 노출, 포커스 중 두 명령 비활성. ⌘F 동작은 유지.
  - F9-2 (medium) 정리 시트 열림·실행 중에도 ⌘R·⌘1~5·⌘↑·배너 재스캔이 동작해 실행 중 재스캔·상태 초기화 가능(startScan 가드가 !isBusy뿐). → AppModel에 `canStartScan`(= !isBusy && cleanupFlow == nil && !isExecutingCleanup && canProceed) 계산 프로퍼티, startScan/rescan 진입부 가드, 메뉴·툴바·배너 disabled 모두 이것 사용. 화면 전환·상위 명령도 cleanupFlow != nil이면 비활성. canStartCleanup에도 !isBusy 포함.
  - F9-3 (low) 검색·칩으로 숨긴 선택이 합계·정리·Return 대상에 남음. → 필터·검색 변경 시 보이지 않는 경로를 선택에서 제거(보이는 행과 교집합).
  - F9-4 (low) 정리 기록 "되돌리기"·iCloud 폴더 "로컬 사본 내리기…" 버튼 라벨에 대상이 없어 VoiceOver 식별 불가. → 행 결합 요약 라벨 + 버튼 accessibilityLabel "되돌리기, <파일 이름>" 형식.
  - F9-5 (low) 되돌리기 결과 행 피드백이 같은 문구 반복 시 안 보임(onChange 의존). → 결과를 행 id와 함께 모델에 기록(예: lastUndo: (rowID, message, seq))해 매번 반영.
  - F9-6 (low) 온보딩 "다시 확인" 후 여전히 미허용이면 피드백 없음. → 인라인 문구 + announce.
  - F9-7 (low) 선버스트 '기타' 조각이 동작 없는 버튼으로 노출, 접근성 요소가 1×1 투명 뷰. → 기타는 읽기 전용 요소(버튼 트레이트 제외), 요소에 조각 위치 기반 accessibilityFrame(또는 실제 크기 오버레이).
  - F9-8 (low) 탐색 선택 바 '정리…' 비활성 사유가 .help에만. → 사유 캡션 표시 + accessibilityHint.
  - F9-9 (low) 정리 계획 완료 시 VoiceOver 공지 없음. → planFinished 후 "정리 계획 준비: N개, 합계 X"(0개면 "정리할 항목 없음") announce.
  - F9-10 (medium) 탐색 행 호버 하이라이트 opacity 0.14 > GUIDELINES §5 상한 10%. → 0.10 이하.
- 영향 범위: StorageLensApp.swift, AppModel.swift, RootView.swift, ExploreView.swift, ExploreSupport.swift, SunburstView.swift, JournalView.swift, ICloudView.swift. 코어(StorageCore) 변경 없음. MainView 유리 미적용(glass-3~6)은 C1 범위.
- 재현/검증: 전체 swift test·경고 0. CleanupFlowMachine 테스트 유지. 가능하면 canStartScan 판단을 순수 함수로 두고 단위 테스트(정리 진행 중 → false). GUI: 검색 필드에서 ⌘⌫가 글자만 지움, 정리 실행 중 ⌘R 무반응.

## F10 — C1 후 잔여 (2026-10-29)
- 오류 원인: ① AppModel.swift에 용어집(Theme.swift 주석) 미적용 문구("귀속 규칙 … 프로그램 귀속", 264행 부근)와 `\(count)개`가 Fmt.count 미경유(613·664행 부근). C1 소유 밖이라 남음. ② DetailPanel(`.inspector` 안, 시스템 유리 패널)의 버튼이 `.glass` → 유리 위 유리(GUIDELINES §1.3).
- 수정 방향: ① 용어집대로 문구 교체, 개수는 Fmt.count. 동작 로직 불변. ② 인스펙터 안 버튼은 기본 스타일(.bordered 또는 기본)로, 주 동작 1개만 필요 시 .borderedProminent 대신 기본 유지. GUIDELINES §5에 "인스펙터·시트 등 시스템 유리 표면 안 컨트롤은 기본 스타일" 추가는 Opus가 함.
- 영향 범위: AppModel.swift(문구만), DetailPanel.swift(버튼 스타일만).
- 재현/검증: grep "귀속\|프로그램" Sources/StorageLensApp → 사용자 문구 0(주석·식별자 제외), DetailPanel에 `.glass` 0. 전체 테스트·경고 0.

## F11 — 최종 검증 발견 + 감사 부분 이행 2건 (2026-10-29)
최종 검증: 클린 release 경고 0, 179/179, Data 볼륨 스캔 12.04s·RSS 482MB(목표 13.5s·0.6GB 이내), 서명 OK, 아이콘·1.2.0 포함. 감사 70건: 완료 66, 대체 2, 부분 2.
- 오류 원인 / 수정 방향:
  - F11-1 (medium, final-2) 선버스트 파일 조각 활성화가 목록에 없는 경로를 selection에 넣음(SunburstView.activate → setSelection) → 요약 0 B·목록 하이라이트 없음·보이지 않는 항목 정리 가능. → 파일 조각은 `reveal(path:)`와 같은 동작(부모 폴더로 포커스 후 선택). setSelection 진입점에서도 현재 rows에 없는 경로는 제외.
  - F11-2 (low, final-3) focus 전환 직후 이전 폴더 rows/arcs가 새 focusPath와 섞여 상호작용 가능. → AppModel에 마지막 반영 폴더(rowsFocusPath) 기록, 불일치 동안 목록·차트 흐림+상호작용(열기·activate) 차단.
  - F11-3 (low, final-1) 자식 5000 초과 폴더에서 검색·칩·이름순이 상위 1000에만 적용되는데 안내 없음. → 잘린 폴더에서는 "상위 1,000개 안에서만 검색·정렬됩니다. 나머지 N개는 Finder에서 확인" 캡션 유지, 빈 결과 설명에도 포함, 요약 행 문구를 "표시 한도를 넘은 나머지 항목"으로 구분.
  - F11-4 (low, final-4) 선버스트 호버 위치 @State가 마우스 이동마다 Canvas 전체 재평가. → 툴팁·위치를 별도 하위 뷰로 분리, 조각이 바뀔 때만 Canvas 입력 변경.
  - F11-5 (low, final-8) 선버스트 조각 이름 검정 고정 → 다크에서 대비 부족. → 조각 색 휘도로 흑/백 선택, Theme 토큰.
  - F11-6 (low, final-5) 앱별 정리 버튼이 사전 가용성 판정 없음. → 체크된 항목의 availability를 비동기 계산(ScanOutcome.cleanupAvailability(forPath:)), 불가 항목은 행에 사유 표시·체크 불가, 버튼 비활성 사유에 반영.
  - F11-7 (low, final-10) 되돌리기 중복 클릭. → 진행 중 row id 집합으로 중복 무시·버튼 비활성. undo 중 스캔 차단은 하지 않음(Opus 판단: undo는 단일 이동이라 짧음).
  - F11-8 (low, final-11) 용어: ExploreView "다시 스캔" 라벨 → "재스캔", OverviewView "카탈로그" 문구 → "정리 안내 목록".
  - F11-9 (partial design-13) 온보딩 "재시작해야 적용" 문구만 있음 → "앱 다시 시작" 버튼(현재 번들을 NSWorkspace로 새로 열고 종료; 정리 실행 중이면 비활성).
  - F11-10 (partial code-quality-9) 저널 크기 정책 없음 → Journal 회전: 2MB 초과 시 append 전에 journal.jsonl → journal.1.jsonl(기존 .1 대체), 읽기(read/journalLoad)는 .1 + 현재를 합쳐 반환, 되돌리기 판정은 기존과 동일. flock 범위 안에서 회전. PLAN §8.2에 정책 기록은 Opus.
- 영향 범위: UI(W1) SunburstView, ExploreView, ExploreSupport, AppModel, AppsView, OverviewView, RootView, Theme. 코어(W2) Cleanup/Journal.swift, Session/CleanupSupport.swift(저널 로드), 테스트.
- 재현/검증: 전체 테스트·경고 0. W2 테스트: 2MB 초과 시 회전·.1 대체·읽기 합본 순서·회전 직후 undo 가능. W1은 빌드+기존 테스트.
