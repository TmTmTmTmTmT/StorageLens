# StorageLens — STATUS

현재: v1.2 완료 · 사용자 GUI 확인 완료 (2026-10-29) (PLAN §17, AUDIT_v1.2.md, GUIDELINES.md, FIX_GUIDE F7~F11). v1.1까지 완료·사용자 확인 완료

## 완료
- M0-T1~T3: 패키지·공통 타입·Support 프로토콜·setiopolicy_np(App.init)·Info.plist·build-app.sh·FDA 온보딩. 첫 서명 빌드 Opus 직접 실행 → Apple Development(Y847SQVUJ2), hardened runtime, verify --strict 통과.
- M1-T1 Scan: getattrlistbulk 256KB, 하드링크 1회, dataless, 상위 200 파일, 취소. 파일: Scan/BulkEnumerator.swift, Scanner.swift
- M1-T2 Attribution: 규칙 1~8, 상속, 고아 추정, AppIndex 빌더, ToolLocator(Support), DownloadOrigin, attribution-rules.json(Apple 데몬 상위 30)
- M1-T3 Catalog: catalog.json 15항목, 우선순위 매처, matchedRoot, 도구 해석 클로저, HuggingFaceInventory
- M1-T4 InUse: libproc openFiles(약 2ms, 380건), InUseIndex 접두 질의
- 수정 F1(고아: 같은 제조사·번들 ID 포함 제외), F2(팀ID+group. 이중 접두), F3(단축어 group 컨테이너 규칙)
- 통합(M1 시점): 56/56 통과
- M2-T1 UI(개요·탐색 선버스트·상세, Session 파사드), M2-T2 이력(HistoryStore, HistoryDiff). F4 카테고리 합계 하위 구체 패턴.
- M3-T1 Cleaner(PathSafety §8.1, plan/execute, 재검증, 저널, undo, Process 직접 실행), M3-T2 정리 시트·정리 기록 UI. F5 Cleaner가 카탈로그 매칭 직접 계산, F6 매처 홈≠realpath면 전부 거부. Opus가 Cleanup/ 직접 검토 완료.
- 통합: swift test 96/96 통과. Cleanup 코드에 removeItem/rm 없음(HistoryStore 자체 이력 파일 정리만).
- 테스트 폴더 `~/Library/Caches/com.kimmingyu.StorageLens.test`(50MB+note.txt) 생성, 앱 재빌드·실행

## 측정
- 성능(Data 볼륨 전체, release, FDA 없는 셸): 12.3~12.5초, 노드 180만, 426.6GB, skipped 911, 최대 메모리 0.53GB → 목표(60초·1.5GB) 충족
- ~/Library 귀속 분포(직속 1,433개, 앱 440): 정확 1040 / 추정 200 / 알 수 없음 162 / 고아 추정 31 (실제 미설치 앱 확인: Perplexity·Tailscale·Docker·NordVPN 등)

- V1 E2E(SL_E2E=1, SessionE2ETests): 실제 홈에서 StorageSession 스캔→history 저장 정상 확인. 테스트 산출물(history 2개)은 삭제, 테스트 폴더 재생성. 주의: 이 테스트는 테스트 폴더를 지우고 다시 만든다.
- 사용자 "전부 OK" 회신했으나 디스크 증거와 불일치 → 미확인 유지
- 2026-10-29 12:49·12:53 앱 스캔 2회 확인(history 2개 생성). 정리 저널 없음(테스트 폴더 정리 미실행)

## v1.1 (PLAN §16, 2026-10-29)
- 사용자 피드백: 창 크기 자동 조절, iCloud 별도 화면, never→비권장(수동 정리 허용), 앱 데이터 정리, 번역·상태 점검
- 사용자 결정: 정리 범위 "개인 폴더까지 열기"(Keychains·Mail·Messages·Photos·.ssh·.gnupg 차단 유지), iCloud "전용 화면"
- V11-T1 완료: Safety discouraged("never" JSON 호환), catalog 18항목, PathSafety 하드/자체만 차단·.photoslibrary 거부, execute(acknowledgedDiscouraged:) 코어 강제. Opus PathSafety 직접 검토 OK. 이탈: SessionTests 2건 §16 의미로 수정(승인)
- V11-T2 완료: AppDataIndex·ICloudInventory·pendingUploads, ScanOutcome 접근자. 전체 110/110
- V11-T3 완료: 사이드바 5화면(앱별·iCloud 신규), 정리 비권장 확인 체크(재계획 시 초기화), 창 크기 자동(화면 75%×80%, 1100 기준 3열/2열, 선버스트 1:1), 진행·오류 배너, ko 로케일. ~/.cache 미귀속은 폴더명 묶음. swift test 111/111
- 서명 빌드 OK: build/StorageLens.app, Apple Development Y847SQVUJ2, runtime, verify --strict 통과, 실행 확인
- 알려진 한계: 스캔 트리 디렉터리당 상위 200 파일만 → Preferences 등 작은 파일 많은 폴더는 앱별 합계 과소. ~/.cache 미귀속 폴더는 T3에서 폴더명 묶음 처리

## 사용자 확인 (완료)
- 2026-10-29 사용자 "완료" 회신: FDA 재빌드 후 유지, M2 귀속 4사례, v1.1 화면(창 크기·앱별·iCloud·한국어)
- M3 정리→휴지통→되돌리기: 디스크 저널로 확인(open-webui 2.28GB trash→undo success, 원위치 복원)

## 다음 단계 후보
- 스캔 트리 디렉터리당 상위 200 파일 한계 → 앱별 합계 과소 (필요 시 Opus 계획)
- ProcessLister.swift:54 String(cString:) deprecated 경고

## Opus 확인 필요
없음 (결정 사항은 PLAN.md §14)

## v1.2 (PLAN §17, 2026-10-29)
- 감사: 6분야 리뷰+적대 검증 → 확인 70건(중 12·하 58), 기각 16. 상세 AUDIT_v1.2.md
- 사용자 결정: 전부 3단계(A 안전→B 사용성→C 디자인·성능), 루트 .build-* 삭제, 앱 아이콘 코드 생성
- 단계 0 완료: 루트 .build-* 9개 삭제(sim-runner). .gitignore에 .build-*/ 추가. v1.1 소스 기준 사본: scratchpad/baseline-v11 (diff 검토용)
- A1 완료(Cleanup 코어): fail-closed 순회(TreeWalker), 휴지통 dev/inode/size 동일성 undo, Journal 공유+flock, iCloud 미업로드 skip, 빈 카탈로그 거부, 취소 skipped. 전체 146/146. Opus PathSafety·Cleaner diff 검토 OK
- A2 완료(Session·Support): ToolLocator xcrun /usr/bin 고정·소유/모드 검사(Homebrew admin 그룹쓰기 허용 — Opus 판단), ResourceLoadStatus, postProcess 취소, 이력 손상 corrupt/ 격리·schemaVersion, build-app.sh 사전 검사
- 사고: A2 변경 직후 A3 전체 테스트가 CleanupTests.virtualCommandItem으로 실제 `/usr/bin/xcrun simctl delete unavailable` 3~4회 실행(13:29~13:32). 이 Mac엔 시뮬레이터 런타임·기기 없음(Devices 비어 있음, 로그 "Unable to discover any Simulator runtimes") → 영향 없음. A1이 테스트 주입(systemToolDirectory) 수정
- A3 완료: 제조사 공용 그룹(vendor:<token>, 폴더명=제조사명 우선), 200파일 한계(AppDataIndex 위치 전부 유지·omittedBytes 반영), 하드링크 결정성, 위치 enum, 규칙7 사전계산. A/B: 시간 11.6~11.8s(기준 11.5~13.1), RSS 468~475MB(기준 554~558). Opus Attributor diff 검토 OK
- A4 완료: CleanupFlowMachine(순수 상태 머신+전수 테스트), 시트 닫기 차단·계획 취소·진행 표시, 로드 상태/이력·저널 손상 배너, 미측정·비표준 도구·iCloud 안내. 이월: AppTerminationGuard 연결(B1), 저널 skipped 표시(B3)
- 단계 A 통합: swift test 156/156, 귀속 정확1041/추정202/알수없음160/고아30, 서명 빌드 OK(Y847SQVUJ2, runtime, verify --strict), 경고 0
- 사용자 GUI 확인(A) 2026-10-29: 정상, 단 이슈 1 → F8(홈 밖 /Library/Application Support/TeamViewer 정리 버튼 활성·시트에서 내부 문구 거부·0개인데 확인 버튼). 홈 밖 정리는 v2 유지, 사전 비활성+문구 개선으로 수정 중
- F8 완료: 홈 밖 경로 정리 사전 비활성(isOutsideHome)+사용자 문구, 0개 시트는 닫기만. 필터 테스트 73/73
- B1 완료: 메뉴·단축키(⌘R ⌘. ⌘1~5 ⌘↑ ⌘F ⌘⌫)·툴바, 종료 경고 연결, FDA 부분 모드 배너·활성화 시 재확인, focusPath 복원, 실패 스트립, 범위 배지, VoiceOver 공지, 진행 150ms 합치기, 선택 Task 취소, overviewCategories. 162/162
- 사용자 지시: Liquid Glass 표준 → GUIDELINES.md 작성, PLAN §17.x
- B2 완료(탐색: 검색·이름순·칩 필터·경로바 생략·컨텍스트 메뉴·Return·행 접근성·선버스트 호버/접근성·inspector·비율 막대·RescanBanner 유리). B3 완료(개요 overviewCategories·reveal, 앱별 정렬·체크 유지·kind.isCache·유리 동작 바, 정리 기록 날짜 그룹·필터·검색·skipped, iCloud 조회 중 비활성, 시트 방법별 버튼·고정 요약·닫고 재스캔). 각 162/162, 경고 0
- 이월(C1): MainView ScanControlBar .borderedProminent 정리, 창 골격 유리 적용
- 단계 B 통합 검증(워크플로): 빌드 경고 0, 162/162, 서명 OK. 리뷰 확인 medium 4(⌘⌫·⌘↑ 검색 중 가로챔, 정리 중 재스캔 가능, 호버 14%), low 다수 → FIX_GUIDE F9. MainView 유리 미적용 4건은 C1
- 운영 판단: 사용자 GUI 확인은 B+C를 묶어 1회(C1이 창 골격 시각을 다시 바꾸므로 중복 확인 방지)
- F9 완료: ScanGate(canStartScan 순수 함수+테스트), 검색 포커스 중 ⌘⌫·⌘↑ 비활성, 숨긴 선택 제거, VoiceOver 라벨, lastUndo, 온보딩 재확인 피드백, 선버스트 기타 읽기 전용, 호버 0.10. 167/167
- C3 완료: 앱 아이콘(scripts/make-icon.swift → Resources/AppIcon.icns, 선버스트 모티프), 버전 build-app.sh VERSION=1.2.0 한 곳, TestSupport.swift 헬퍼 공용화. 167/167
- C1(Liquid Glass 창 골격·Theme·Components·용어집·선버스트 색)·C2(arcs detached·rows LRU·InUse 링크 생략·IconProvider 캐시) 병렬 진행
- C2 완료: rows+arcs 같은 detached 작업·세대 토큰, rows LRU 16, InUse 실경로 질의(링크 자식은 링크 자체 기준 — Opus 승인), 자식 5000 초과 상위 1000+요약, IconProvider 비동기·음성 캐시·64px·512 상한. 20,000자식 폴더 257ms→7ms. 179/179
- C1 완료: Theme.swift 토큰·용어집, Components.swift 공용 배지/배너, 창 골격 FloatingStack(유리 카드 스택)·툴바 Spacer·navigationSubtitle·glassProminent 화면당 1, 선버스트 라이트/다크 팔레트 캐시, 증감 화살표·안전도 아이콘, §4 금지 grep 0. 179/179
- F10 진행: AppModel 잔여 문구, 인스펙터 안 .glass → 기본 스타일
- 최종 검증(워크플로, 1차는 사용량 한도로 중단→재실행): 클린 release 경고 0, 179/179, Data 볼륨 12.04s·RSS 482MB(기준 11.6~11.8s·468~475MB, 목표 이내), 서명·아이콘·1.2.0 OK. 감사 70건 완료66·대체2·부분2(design-13 재시작 버튼, cq-9 저널 회전). 리뷰 확인 medium1·low7 → FIX_GUIDE F11. 참고: release 테스트 빌드는 -Xswiftc -enable-testing 필요
- F11 완료: W1(선버스트 파일 조각 reveal·setSelection 목록 교집합, rowsFocusPath 불일치 시 흐림·차단, 5000 초과 안내, 호버 하위 뷰 분리, 라벨 흑/백 휘도, 앱별 가용성 사전 판정, undo 중복 차단, 용어, 온보딩 재시작 버튼) · W2(저널 2MB 회전·합본 읽기, 테스트 6). 185/185. JournalView 버튼 비활성 마무리+서명 빌드 진행
- JournalView undo 진행 중 비활성 반영. 최종: 경고 0, 185/185, 서명 빌드 OK(Y847SQVUJ2, runtime, verify --strict)
- 사용자 GUI 확인(B+C) 2026-10-29: All OK
