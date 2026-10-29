# StorageLens v1.2 감사 결과 (2026-10-29)

6분야 리뷰 + 적대적 검증으로 확인된 항목. 수정 배정은 PLAN.md §17 표, 지침은 FIX_GUIDE.md F7. 각 항목: 근거(원인)·영향·수정 방향·대상 파일.

## usability

### usability-1 [medium] 앱 메뉴/키보드 단축키 전무 (재스캔·화면 전환·검색·정리·상위로)
- 파일: Sources/StorageLensApp/StorageLensApp.swift:19-27, Sources/StorageLensApp/ExploreView.swift:93-102, Sources/StorageLensApp/CleanupSheet.swift:95-96
- 원인/근거: Scene에 .commands가 없고, 앱 전체에서 keyboardShortcut은 정리 시트 '취소' 1곳(CleanupSheet:95)뿐이다. grep으로 searchable·onKeyPress·contextMenu도 0건. 탐색 목록은 더블클릭(ExploreView:99)만 폴더 진입을 지원한다.
- 영향: 스캔 시작/재스캔(⌘R), 사이드바 전환(⌘1~5), 상위 폴더(⌘↑), 폴더 진입(Return), 정리(⌘⌫), 검색(⌘F)을 마우스로만 해야 한다. 우클릭 메뉴(Finder에서 보기, 경로 복사, 정리)도 없어 파워 유저 효율과 발견 가능성이 낮다.
- 수정 방향: 앱 Commands에 스캔/재스캔, 화면 이동, 상위로, 검색 포커스를 등록한다. 탐색 목록에 Return 진입, 행 컨텍스트 메뉴(Finder에서 보기·경로 복사·정리…)를 추가한다. 정리 시트 확인 버튼에는 기본 동작 단축키를 지정한다.
- 검증 메모: 확인: StorageLensApp.swift Scene에 .commands 없음, keyboardShortcut은 CleanupSheet:95 취소 1곳뿐, contextMenu/searchable/onKeyPress 0건. 폴더 진입은 더블클릭뿐(ExploreView:99). 근거 정확.

### usability-2 [medium] 정리 시트 실행 중 Esc/외부 닫힘 시 결과가 사라짐, 계획·실행 단계에는 닫기 수단도 없음
- 파일: Sources/StorageLensApp/MainView.swift:36-38, Sources/StorageLensApp/CleanupSheet.swift:14-19, Sources/StorageLensApp/AppModel.swift:300-313
- 원인/근거: 시트는 .sheet(item: $model.cleanupFlow)로 열리고 interactiveDismissDisabled가 없다. planning/executing 단계 UI는 ProgressView뿐이다(CleanupSheet:15,19). Esc로 닫히면 바인딩이 cleanupFlow=nil로 만들 뿐 closeCleanup이 호출되지 않는다. confirmCleanup의 Task는 계속 실행된다.
- 영향: 실행 도중 Esc를 누르면 파일이 실제로 휴지통으로 이동하는데도 결과·실패 사유·휴지통 안내를 볼 수 없다. 사용자는 성공 여부를 모른 채 정리 기록 화면에서 추정해야 한다. 계획 단계가 길어지면 취소 버튼이 없어 갇힌 느낌이다.
- 수정 방향: executing 단계에서는 시트 닫기를 비활성화하고, planning 단계에는 취소를 제공한다. 닫힘 경로를 모두 closeCleanup으로 통일한다. 실행이 끝나면 결과 시트가 반드시 보이도록 보장한다.
- 검증 메모: 확인: MainView:36 sheet(item:)에 interactiveDismissDisabled 없음, planning/executing은 ProgressView뿐(CleanupSheet:15,19), closeCleanup은 버튼에서만 호출되고 confirmCleanup의 Task는 계속 실행(AppModel:300-309). Esc로 닫으면 결과 시트를 못 봄. 정리 기록에는 남으므로 데이터 손실은 아님.

### usability-3 [low] 탐색 화면에서 다중 선택 시 선택 개수·합계 크기 요약이 없음 (앱별 화면과 불일치)
- 파일: Sources/StorageLensApp/ExploreView.swift:75-91, Sources/StorageLensApp/ExploreView.swift:167-181, Sources/StorageLensApp/AppModel.swift:211-235
- 원인/근거: CleanupButton은 비활성일 때 사유만 보여주고, 활성일 때는 '정리…' 버튼만 있다. 선택 수·합계 표시가 없다. 다중 선택이면 select(nil)로 상세 패널이 사라진다(AppModel:214). 반면 AppsView 푸터는 '선택 N개 · 크기'를 보여준다(AppsView:168).
- 영향: 여러 항목을 골랐을 때 얼마를 정리할지 시트를 열기 전에는 알 수 없다. 오른쪽 패널도 비어 선택 상태 피드백이 약하다.
- 수정 방향: 정렬 바나 하단에 '선택 N개 · 합계 X' 요약을 상시 표시한다. 다중 선택일 때 상세 패널은 요약 카드로 대체한다. 앱별 화면과 같은 문구·배치를 쓴다.
- 검증 메모: 확인: CleanupButton(ExploreView:167-181)에 선택 수/합계 없음, 앱별 푸터는 있음(AppsView:168). 다만 정리 시트 미리보기에서 합계를 확인한 뒤 실행하므로 안전 문제는 없어 low로 하향.

### usability-4 [low] 탐색 목록에 검색·필터·이름순 정렬이 없고, '작은 파일 N개' 요약 행은 열람 불가
- 파일: Sources/StorageLensApp/ExploreView.swift:75-102, Sources/StorageCore/Session/ScanOutcome.swift:123-142
- 원인/근거: 정렬은 크기/수정일 세그먼트 2개뿐이다(ExploreView:78-79). 검색 필드와 유형·귀속·안전도 필터가 없다. rows()는 폴더의 모든 자식을 나열하고, 생략된 작은 파일은 선택 불가 요약 행(.tag(nil), ExploreView:97)으로만 보인다.
- 영향: 수백 개 항목이 있는 폴더(예: ~/Library/Caches)에서 특정 앱·이름을 찾으려면 스크롤밖에 없다. 이름순 정렬도 없다. 요약 행에 포함된 파일은 앱 안에서 볼 방법이 없다.
- 수정 방향: 현재 폴더 범위 이름 검색과 이름순 정렬을 추가한다. '사용 중', '비권장', '고아 추정' 같은 칩 필터를 고려한다. 요약 행은 '앱에서 표시하지 않음' 설명을 붙이거나 Finder 열기를 제공한다.
- 검증 메모: 확인: 정렬은 크기/수정일 2개뿐(ExploreView:78-79), 검색·필터 없음. PLAN에 의도적 제외 근거 없음. 다만 기능 추가 성격이라 low.

### usability-5 [low] 재스캔 시 탐색 위치·선택이 루트로 초기화되고, 정리 후 재스캔 동선이 길다
- 파일: Sources/StorageLensApp/AppModel.swift:169-183, Sources/StorageLensApp/CleanupSheet.swift:146-150, Sources/StorageLensApp/ExploreView.swift:183-195
- 원인/근거: finish()가 focusPath를 logicalRootPath로 되돌리고 selection·detail을 비운다(AppModel:179-181). 결과 화면에는 '재스캔을 권장합니다' 문구만 있고 재스캔 버튼이 없다(CleanupSheet:147). 사용자는 닫은 뒤 화면별 RescanBanner를 눌러야 한다. 재스캔은 항상 전체 스캔이다.
- 영향: 깊은 폴더를 정리하고 재스캔할 때마다 처음부터 다시 내려가야 한다. 정리→확인→재스캔 흐름이 끊긴다.
- 수정 방향: 재스캔 완료 후 가능하면 이전 focusPath(존재하지 않으면 가장 가까운 상위)를 복원한다. 결과 단계에 '닫고 재스캔' 버튼을 추가한다. 정리한 하위 경로만 부분 갱신하는 방안은 Opus가 범위를 판단한다(§10 관련 여부 확인 필요).
- 검증 메모: 확인: finish()가 focusPath를 logicalRootPath로 초기화(AppModel:179), 결과 화면에 재스캔 버튼 없음(CleanupSheet:147), 배너로만 재스캔. 불편함 수준이라 low.

### usability-6 [medium] FDA 부분 스캔으로 진입한 뒤 권한 안내·설정 재진입 경로가 없음
- 파일: Sources/StorageLensApp/RootView.swift:16-31, Sources/StorageLensApp/RootView.swift:42-76, Sources/StorageLensApp/OverviewView.swift:38-42
- 원인/근거: canProceed는 status != .denied || continuePartial 이므로, 한 번 '부분 스캔으로 계속'을 누르면 MainView로 간 뒤 온보딩으로 돌아갈 UI가 없다. 개요 휴지통 행은 '전체 디스크 접근 권한 필요'라고만 쓰고 설정 열기 버튼이 없다. .undetermined 상태도 아무 안내 없이 통과한다. 온보딩은 앱 재활성화 시 자동 재확인하지 않는다.
- 영향: 권한을 나중에 허용하려는 사용자는 개요 문구를 보고도 어디서 해야 하는지 모르고, 결과가 왜 부정확한지 알기 어렵다. 앱 재시작도 사용자가 직접 해야 한다.
- 수정 방향: 부분 모드에서는 상단에 지속 배너(권한 제한, 시스템 설정 열기, 다시 확인)를 표시한다. 앱이 활성화될 때 FDA를 자동 재확인한다. '접근 불가 N곳' 안내와 연결한다. 미사용 MainPlaceholderView(RootView:33)는 정리한다.
- 검증 메모: 확인: canProceed=status != .denied || continuePartial(RootView:16)이라 부분 모드에서 온보딩 복귀 UI 없음, 개요 휴지통 행은 문구만 있고 설정 열기 버튼 없음(OverviewView:38-42). 앱 활성화 시 재확인 부재와 MainPlaceholderView 미사용은 정독 수준에서 정황상 맞음(RootView:33).

### usability-7 [low] 개요의 카테고리·증감 목록이 막다른 길 (클릭해도 해당 위치로 이동 불가)
- 파일: Sources/StorageLensApp/OverviewView.swift:68-96, Sources/StorageLensApp/OverviewView.swift:98-116
- 원인/근거: 카테고리 행(OverviewView:73-80)과 증감 상위 10 행(103-109)은 Text 나열일 뿐 Button·링크·onTapGesture가 없다. 증감 행은 경로를 보여주지만 탐색으로 가는 방법이 없다.
- 영향: '가장 많이 늘어난 폴더'를 알아도 곧바로 탐색에서 열거나 정리할 수 없다. 개요가 정보 표시에 그쳐 핵심 흐름(발견→조치)이 끊긴다.
- 수정 방향: 증감 행은 클릭 시 탐색 화면에서 해당 경로로 포커스한다. 카테고리 행은 해당 항목 목록으로 이동하거나 펼친다. 호버 시 이동 가능하다는 어포던스를 준다.
- 검증 메모: 확인: OverviewView 카테고리 행·증감 행은 Text/HStack뿐이고 탭/버튼 없음(73-80, 103-109). 정보 표시 화면의 연동 부재라 low.

### usability-8 [low] iCloud '로컬 사본 내리기'가 업로드 대기 조회 결과와 연동되지 않음
- 파일: Sources/StorageLensApp/ICloudView.swift:89-90, Sources/StorageLensApp/ICloudView.swift:107-108, Sources/StorageLensApp/ICloudView.swift:118-137, Sources/StorageLensApp/CleanupSheet.swift:35-100
- 원인/근거: 컨테이너/하위 폴더의 내리기 버튼은 model.isBusy로만 비활성화된다. pendingState가 .running이거나 pending>0이어도 활성이다. 시트 미리보기에는 업로드 대기 수가 나오지 않는다. 경고는 pendingRow 문구뿐이다. 하위 폴더 행마다 같은 컨테이너 단위 조회 결과가 적용되는지도 표시되지 않는다.
- 영향: 조회가 끝나기 전이나 대기 파일이 있는데도 바로 내리기를 눌러 일부 실패하거나 업로드 전 파일을 건드릴 수 있다. 사용자는 경고와 버튼이 분리되어 있어 놓치기 쉽다.
- 수정 방향: 조회 중에는 버튼에 안내를 붙이거나 비활성화한다. pending>0이면 시트 경고에 개수를 포함하고 추가 확인을 요구한다. 폴더 단위 경고의 범위(컨테이너 전체인지)를 문구로 명확히 한다.
- 검증 메모: 확인: 내리기 버튼은 model.isBusy로만 비활성(ICloudView:89-90,107-108), pendingState 미연동. 다만 pendingRow가 바로 위에 경고를 표시하고(118-137) 문구도 '실패할 수 있습니다'로 안내해 데이터 손실 위험은 낮음. 시트에 대기 수 미표시는 미확인.

### usability-9 [low] 선버스트에 호버 툴팁·이름 표기·접근성 정보가 없음
- 파일: Sources/StorageLensApp/SunburstView.swift:19-31, Sources/StorageLensApp/SunburstView.swift:42-55, Sources/StorageLensApp/OverviewView.swift:138-146
- 원인/근거: 조각은 Canvas로 그려지며 hover 처리가 없다. .help는 고정 안내문 하나뿐이다(SunburstView:55). 클릭하면 폴더면 이동, 파일이면 선택한다. accessibility 수식어는 앱 전체 0건이다. VolumeBar도 색 막대뿐이다.
- 영향: 조각이 무엇이고 얼마인지 알려면 클릭(폴더는 이동)해야 하고, 탐색 상태가 바뀐다. 색조만으로 구분되는 부분이 있고 VoiceOver 사용자는 차트를 쓸 수 없다.
- 수정 방향: 호버 시 이름·크기·비율 툴팁과 목록 행 하이라이트 연동을 추가한다. VolumeBar와 차트에 접근성 라벨·값을 제공한다. 클릭 동작(이동/선택) 구분을 명확히 한다.
- 검증 메모: 확인: SunburstView는 Canvas+onTapGesture, hover 처리 없음, .help는 고정 문구(55), accessibility 수식어 grep 0건. 실제이나 개선 성격이라 low.

### usability-10 [low] 정리 시트 확인 버튼 문구가 모호하고 위험 요약이 목록 하단에 몰려 있음
- 파일: Sources/StorageLensApp/CleanupSheet.swift:89-99, Sources/StorageLensApp/CleanupSheet.swift:35-60
- 원인/근거: 실행 버튼 이름은 '확인'이다(CleanupSheet:96). 총 크기는 하단 작은 글씨(91-92)다. 방법(휴지통/도구 실행/내리기)은 항목 내 caption이다. 거부 항목은 같은 스크롤 안에 있다.
- 영향: 무엇이 일어나는지(휴지통 이동인지 명령 실행인지)와 몇 GB인지를 버튼에서 알 수 없다. 항목이 많으면 중요한 경고가 스크롤에 가려진다.
- 수정 방향: 버튼에 동작+규모를 담는다(예: '휴지통으로 이동 (N개, 크기)'). 상단에 방법·합계·비권장 개수 요약을 고정한다. 거부 항목은 접이식으로 분리한다.
- 검증 메모: 확인: 버튼 문구 '확인'(CleanupSheet:96), 합계는 하단 callout(91-92). 정리 동작 명시 부족은 사실.

### usability-11 [low] 정리 기록: 되돌릴 수 없는 항목에 설명이 없고, 필터·검색·그룹이 없으며 전체를 한 번에 로드
- 파일: Sources/StorageLensApp/JournalView.swift:26-34, Sources/StorageLensApp/JournalView.swift:76-83, Sources/StorageLensApp/AppModel.swift:322-343
- 원인/근거: 되돌리기 버튼은 method == trash일 때만 표시된다(JournalView:81). command·icloudEvict 항목은 버튼도 사유 문구도 없다. 목록은 검색·기간·결과 필터 없는 평면 List다. undoMessage는 수동으로 닫을 때까지 남는다. 되돌리기 전 확인도 없다.
- 영향: 도구 실행이나 내리기가 왜 되돌려지지 않는지 알 수 없다. 기록이 쌓이면 특정 항목을 찾기 어렵다. 같은 시점의 정리가 항목별로 흩어진다.
- 수정 방향: 되돌릴 수 없는 방법에는 이유를 한 줄로 표시한다(예: 도구 실행은 복구 불가). 날짜별 그룹, 결과 필터, 검색을 추가한다. 되돌리기 결과는 토스트나 행 단위 피드백으로 보여준다.
- 검증 메모: 부분 확인: 되돌릴 수 없음 사유는 method==trash일 때만 표시(JournalView:76-77), command/icloudEvict는 버튼도 사유도 없음. 필터/검색 부재와 전체 로드는 정황상 맞으나 일부 미정밀 확인.

### usability-12 [low] 스캔 실패 상태에서 재시도·닫기 수단이 없고 다른 화면에서는 중복 표시됨
- 파일: Sources/StorageLensApp/MainView.swift:14-18, Sources/StorageLensApp/MainView.swift:112-114, Sources/StorageLensApp/MainView.swift:122-142, Sources/StorageLensApp/MainView.swift:150-162
- 원인/근거: 실패 시 ScanProgressDetail은 빨간 Label만 보여주며 버튼이 없다(MainView:112-114). 개요에서는 ScanControlBar가 시작 버튼을 다시 보여주지만, 다른 화면 상단 스트립에는 재시도·닫기가 없다. 스캔 결과가 없는 화면에서는 NoScanView가 ScanControlBar를 포함해 스트립과 같은 오류 문구가 두 번 나온다. 사용자 취소(state=.idle)에도 '취소됨' 피드백이 없다.
- 영향: 실패 원인(권한·경로 등)에 대한 다음 행동 안내가 없다. 오류 문구가 해제되지 않고 남는다.
- 수정 방향: 실패 스트립에 '다시 시도'와 '닫기'를 둔다. 중복 표시를 정리한다. 취소 시 짧은 상태 문구를 표시한다.
- 검증 메모: 확인: .failed 상태는 빨간 Label뿐 재시도/닫기 없음(MainView:112-114), NoScanView가 ScanControlBar(진행 상세 포함)를 넣어 스트립과 중복 가능. 취소 피드백 부재는 코드상 .idle로 돌아가는 것으로 정황 부합.

### usability-13 [low] 탐색 경로바가 깊은 경로에서 넘치고 핵심 버튼이 밀려남
- 파일: Sources/StorageLensApp/ExploreView.swift:59-73
- 원인/근거: breadcrumb는 모든 구성요소를 단일 HStack에 Button으로 나열하고 Spacer 뒤에 크기와 재스캔 아이콘을 둔다. 스크롤·축약(lineLimit/ScrollView)이 없다. 창 최소폭은 760(StorageLensApp:23).
- 영향: 깊은 폴더에서 경로가 잘리거나 크기·재스캔 버튼이 보이지 않을 수 있다. 재스캔 아이콘에는 .help 외 레이블이 없다.
- 수정 방향: 경로를 가로 스크롤 또는 중간 생략(…) 방식으로 축약하고, 우측 컨트롤은 고정한다. 마지막 컴포넌트를 우선 보이게 한다.
- 검증 메모: 확인: breadcrumbBar가 단일 HStack에 모든 구성요소를 나열하고 스크롤/축약 없음(ExploreView:59-73). 깊은 경로에서 레이아웃 압박 가능.

### usability-14 [low] 앱별 항목 테이블에 정렬 불가, 비활성 사유 미표시, 체크 상태가 보이지 않게 유지됨
- 파일: Sources/StorageLensApp/AppsView.swift:123-153, Sources/StorageLensApp/AppsView.swift:156-178, Sources/StorageLensApp/AppsView.swift:33-37
- 원인/근거: Table(g.items)에 sortOrder가 없어 컬럼 헤더 정렬이 불가하다. '선택 항목 정리…'는 isBusy나 빈 선택일 때 이유 없이 비활성이다(AppsView:175). 그룹 전환 시 체크 상태가 그룹별로 보존되고, 재스캔하면 전부 초기화된다(34-37).
- 영향: 큰 항목을 찾기 위한 정렬이 안 되고, 버튼이 왜 안 눌리는지 모른다. 사용자가 이전에 체크한 상태가 재스캔 뒤 사라진다.
- 수정 방향: 크기·수정일·안전도 컬럼 정렬을 켠다. 비활성 사유를 푸터에 표시한다. 재스캔 후 동일 경로의 체크를 유지할지 검토한다.
- 검증 메모: 부분 확인: Table(g.items)에 sortOrder 없음(AppsView:123), 재스캔 시 checked 초기화(AppsView:34-37). 비활성 사유 미표시는 푸터에 '선택 0개'가 보이므로 과장 소지가 있음.

### usability-15 [low] 스캔 진행률이 불확정이고 폴더 지정 스캔 시 범위 표시가 화면 간 일관되지 않음
- 파일: Sources/StorageLensApp/MainView.swift:82-111, Sources/StorageLensApp/MainView.swift:122-146, Sources/StorageLensApp/AppModel.swift:130-135
- 원인/근거: 진행은 항목 수·바이트·경과·현재 경로만 보여주며 전체 대비 비율이나 예상 시간이 없다. 폴더 지정 스캔(MainView:132)이 outcome을 하위 트리 결과로 대체하지만, 앱별·iCloud 화면에는 '일부 범위' 표시가 없다. 그 화면의 빈 상태 문구가 힌트가 될 뿐이다.
- 영향: 첫 전체 스캔이 얼마나 걸릴지 알 수 없다. 부분 범위 결과를 전체로 오해할 수 있다.
- 수정 방향: 볼륨 사용량 대비 바이트 진행률 추정치 또는 지난 스캔 소요 시간을 참고용으로 표시한다. 부분 스캔이면 모든 화면 상단에 현재 범위 배지를 보인다.
- 검증 메모: 부분 확인: 진행 표시는 항목 수/바이트/경과만(MainView:82-111), 전체 대비 비율 없음. 폴더 지정 스캔의 범위 배지 부재는 정황상 맞으나 화면별 전수 확인은 미완.

## design

### design-1 [medium] 선버스트에 라벨·범례·호버 정보가 전혀 없어 조각이 무엇인지 알 수 없음
- 파일: Sources/StorageLensApp/SunburstView.swift
- 원인/근거: SunburstView.swift:19-31은 Canvas로 호만 채우고 텍스트를 그리지 않는다. 안내는 :55 `.help`(뷰 전체에 하나뿐인 정적 문구)뿐이고 조각별 호버/툴팁/하이라이트가 없다. 색은 :73-80에서 깊이 1 조각의 중심각을 색조로 쓰는 고정 채도 0.55로, 이름과의 대응 범례가 없다. 목록과 색이 연결되지도 않는다(NodeRowView에는 색 표시 없음).
- 영향: 핵심 시각화인데 클릭해 보기 전에는 조각의 이름·크기를 알 수 없다. 좁은 조각은 구분이 어렵고 목록 행과 조각의 대응 관계도 보이지 않는다.
- 수정 방향: 마우스 호버 시 조각 이름·크기·비율을 가운데 또는 팝오버로 보여주고, 해당 목록 행과 상호 하이라이트한다. 큰 조각에는 이름을 직접 표기하고, 목록 행에 같은 색의 마커를 두어 대응시킨다.
- 검증 메모: SunburstView.swift에서 Canvas가 호만 그리고 텍스트·조각별 호버가 없으며 .help는 뷰 전체 정적 문구 하나뿐임을 확인. 색은 깊이1 중심각 기반이고 NodeRowView에도 색 표시 없음. 선택 시 상세 패널이 있어 완전 사용 불가는 아니나 핵심 시각화의 정보 부재는 실제.

### design-2 [low] 좁은 창(760~1100)에서 상세 패널이 목록을 덮는 오버레이로 동작하고 기본이 '표시'
- 파일: Sources/StorageLensApp/ExploreView.swift
- 원인/근거: ExploreView.swift:48-56은 !wide일 때 DetailPanel을 `.overlay(alignment: .trailing)`으로 폭 min(detailW+40, width*0.55)만큼 올린다. showDetail 기본값은 true(:7)다. 최소 창 760에서 콘텐츠 폭은 약 590이라 선버스트 240, 목록 약 350, 패널 약 300이 되어 목록의 크기·수정일 열이 거의 가려진다. PLAN §16.5는 '목록 아래 또는 접이식'으로 정했는데 구현은 겹침이다.
- 영향: 행을 하나 선택하면 방금 선택한 행의 크기 숫자와 우측 정보가 패널에 가려져 목록 작업이 불편하다. 사용자가 토글 버튼을 직접 찾아 꺼야 한다.
- 수정 방향: 좁은 폭에서는 패널을 레이아웃에 포함해 목록 영역과 공간을 나누거나 목록 아래로 배치한다. 오버레이를 유지한다면 기본값을 숨김으로 하고, 선택 시에만 열도록 하며 닫기 어포던스를 패널 안에 둔다.
- 검증 메모: ExploreView.swift:48-56 오버레이와 showDetail 기본 true 확인, 최소 폭에서 패널(약 300)이 목록 일부를 가림. 그러나 PLAN §16.5는 '목록 아래 또는 접이식(토글 버튼)'이고 토글(:84)이 구현돼 있어 '결정과 어긋남'은 과장. 패널은 행 선택 시에만 뜨고 토글로 닫을 수 있어 low.

### design-3 [low] 3열 전환 기준이 창 폭이 아니라 상세 컬럼 폭이라 PLAN §16.5 결정과 어긋남
- 파일: Sources/StorageLensApp/ExploreView.swift, Sources/StorageLensApp/MainView.swift
- 원인/근거: ExploreView.swift:16-17의 GeometryReader는 NavigationSplitView detail 컬럼의 폭이고 사이드바(ideal 170, MainView.swift:12)가 빠진다. :27 `wide = width >= 1100`은 따라서 창 폭 약 1270 이상에서만 참이다. PLAN §16.5는 '폭 ≥ 1100이면 3열'이라 서술한다. 반면 AppsView.swift:24, ICloudView.swift:34는 MainView.swift:29-35가 잰 전체 창 폭(사이드바 포함)의 비율로 열 폭을 계산해 기준이 화면마다 다르다.
- 영향: 1100~1270 창에서는 의도한 3열 레이아웃이 나오지 않는다. 화면별 폭 기준이 달라 같은 창 크기에서 비율이 일관되지 않는다.
- 수정 방향: 기준을 하나로 정한다(콘텐츠 영역 기준이라면 임계값을 조정하고 PLAN 문구를 갱신, 창 기준이라면 사이드바 폭을 보정). 열 폭 계산은 각 화면이 자기 컨테이너의 GeometryReader를 쓰도록 통일한다.
- 검증 메모: GeometryReader가 detail 컬럼 폭(사이드바 제외)이라 실제 3열 전환은 창 폭 약 1270 이상에서만 발생함을 확인. PLAN 문구가 '폭'이라 모호하고 기능 영향은 작음. 화면별 폭 기준 불일치(AppsView/ICloudView는 windowSize 사용)도 사실이나 low.

### design-4 [low] 툴바·메뉴 명령·단축키가 없고 주요 동작이 본문 안 버튼에만 흩어져 있음
- 파일: Sources/StorageLensApp/MainView.swift, Sources/StorageLensApp/ExploreView.swift, Sources/StorageLensApp/OverviewView.swift, Sources/StorageLensApp/StorageLensApp.swift
- 원인/근거: Sources/StorageLensApp 전체에 `.toolbar`, `.commands`, 단축키(`keyboardShortcut`은 CleanupSheet.swift:95의 취소 하나뿐)가 없다. 스캔 시작은 OverviewView/NoScanView 안의 ScanControlBar(MainView.swift:130), 재스캔은 탐색 화면 이동 경로 줄의 아이콘 버튼(ExploreView.swift:69), 정리는 정렬 줄 안 버튼(:88), 취소는 진행 줄 안에 있다. 사이드바에도 스캔 상태 표시가 없다.
- 영향: macOS 관례(툴바/메뉴, ⌘R 재스캔, ⌘F 검색 등)를 따르지 않아 화면마다 같은 동작 위치가 달라지고 키보드 사용자는 접근 경로가 없다.
- 수정 방향: 스캔 시작/재스캔/취소와 정리를 창 툴바와 메뉴 명령으로 올리고 ⌘R, ⌘⌫ 등 표준 단축키를 부여한다. 화면 본문 버튼은 보조로 둔다.
- 검증 메모: 전체에서 .toolbar/.commands/단축키 없음(CleanupSheet 취소 제외), StorageLensApp.swift에 commands 없음 확인. macOS 관례 미준수는 사실이나 기능은 본문 버튼으로 모두 접근 가능하므로 low~medium 중 low.

### design-5 [low] 파괴적 동작 버튼 문구가 모호함('확인', 'Finder에서 …' 등)
- 파일: Sources/StorageLensApp/CleanupSheet.swift, Sources/StorageLensApp/ExploreView.swift, Sources/StorageLensApp/AppsView.swift
- 원인/근거: CleanupSheet.swift:96의 실행 버튼 라벨이 '확인'이다. 같은 동작이 탐색 화면에서는 '정리…'(ExploreView.swift:177), 앱별 화면에서는 '선택 항목 정리…'(AppsView.swift:173), iCloud 화면에서는 '로컬 사본 내리기…'(ICloudView.swift:89)로 서로 다르다. 정리 시트 제목 '정리: …'(:11)와 버튼 문구가 이어지지 않는다.
- 영향: 되돌릴 수 있는 휴지통 이동이든 도구 실행이든 같은 '확인' 버튼으로 실행되어 무슨 일이 일어나는지 확신하기 어렵다.
- 수정 방향: 실행 버튼을 동작이 드러나는 문구('휴지통으로 이동', '정리 실행' 등 방법별)로 바꾸고, 비권장 항목 포함 시 시각적으로 구분한다. 진입 버튼 문구도 용어집을 정해 통일한다.
- 검증 메모: CleanupSheet.swift:96 실행 버튼이 '확인'이고 진입 문구가 화면마다 다름을 확인. 다만 시트가 항목 경로·크기·비권장 경고(빨간 박스, 확인 체크 필수)를 모두 보여준 뒤 누르는 버튼이라 위험은 낮음. 문구 다듬기 수준.

### design-6 [low] 한국어 용어 일관성 부족과 내부 개념 노출('귀속', '고아 추정', '프로그램', 'v2')
- 파일: Sources/StorageLensApp/MainView.swift, Sources/StorageLensApp/DetailPanel.swift, Sources/StorageLensApp/AppsView.swift, Sources/StorageLensApp/OverviewView.swift, Sources/StorageLensApp/ExploreView.swift
- 원인/근거: '귀속·카테고리 계산 중…'(MainView.swift:108), '귀속 근거'(DetailPanel.swift:32), '프로그램' 소제목(:25)인데 다른 곳은 '앱'을 쓴다. 같은 상태를 DetailPanel.swift:27과 ExploreView.swift:145는 '삭제된 앱의 데이터로 추정', AppsView.swift:202는 '고아 추정'이라 쓴다. OverviewView.swift:180은 사용자 문구에 '(v2)'를, :12는 'build-app.sh로 만든 앱에서 실행하세요'를 노출한다. 건수 표기도 Fmt.count를 쓰는 곳과 `\(items.count)`(OverviewView.swift:189), `\(discouraged.count)`(CleanupSheet.swift:77)처럼 쓰지 않는 곳이 섞여 있다.
- 영향: 일반 사용자에게 낯선 용어와 개발자용 문구가 보이고, 같은 개념이 화면마다 다른 말로 불린다.
- 수정 방향: 용어 목록(앱/귀속→'소속 앱', 고아 추정 등)을 정해 전 화면에 적용하고, 개발 안내·버전 문구는 제거하거나 일반 안내로 바꾼다. 숫자 표기는 모두 Fmt.count를 거치게 한다.
- 검증 메모: '귀속·카테고리 계산 중'(MainView:108), '귀속 근거'·'프로그램'(DetailPanel), '고아 추정'(AppsView) vs '삭제된 앱의 데이터로 추정', OverviewView의 '(v2)'와 build-app.sh 안내, 직접 \(items.count) 사용 모두 확인.

### design-7 [low] 개요 화면의 정보 위계와 시각화 부족(카테고리는 텍스트 표, 카드 제목 불일치)
- 파일: Sources/StorageLensApp/OverviewView.swift
- 원인/근거: OverviewView.swift:68-95의 카테고리별 합계는 이름·안전도·크기 텍스트만 있어 비율 막대가 없고 선버스트나 용량 막대와 색 연결도 없다. 휴지통(:35-48)과 iCloud(:50-66)는 제목 없이 회색 카드로, 카테고리·증감·Hugging Face는 `.headline` 제목으로 표시되어 위계가 섞인다. 용량 막대(:132-164)가 스캔 제어 줄 아래에 있어 핵심 요약이 첫 화면 상단에 오지 않는다.
- 영향: 개요 화면에서 어디에 공간이 쓰이는지 한눈에 보이지 않고 숫자를 일일이 읽어야 한다.
- 수정 방향: 용량 요약을 최상단에 두고 카테고리별 합계에 비율 막대를 추가한다. 섹션 제목과 카드 스타일을 통일하고 스캔 제어는 툴바나 보조 영역으로 옮긴다.
- 검증 메모: categorySection이 이름·SafetyTag·크기 텍스트만이고 비율 막대 없음, 휴지통/iCloud 카드는 제목 없음, VolumeBar가 ScanControlBar 아래임 확인. 정보는 모두 있으며 시각화 개선 성격이라 medium은 과장.

### design-8 [low] 목록 행에 상대 크기 표시가 없어 정보 밀도가 낮음
- 파일: Sources/StorageLensApp/ExploreView.swift
- 원인/근거: NodeRowView(ExploreView.swift:105-136)는 아이콘·이름·귀속 줄·크기·수정일만 있다. 상위 대비 비율이나 막대가 없어 2줄 행이 높이를 차지하는 데 비해 크기 비교 정보는 숫자뿐이다. 사용 중 표시(:116)는 caption2 크기의 `circle.fill` 라벨이다.
- 영향: 디스크 분석 앱의 핵심인 '무엇이 가장 큰가'를 숫자를 읽어 비교해야 한다.
- 수정 방향: 각 행에 상위 항목 대비 비율 막대(또는 백분율)를 넣고 사용 중 표시는 의미가 분명한 아이콘/배지 스타일로 교체한다.
- 검증 메모: NodeRowView에 비율 막대/백분율 없음 확인. 정렬은 크기순이라 비교는 가능. 개선 제안 성격의 low.

### design-9 [low] 이동 경로(breadcrumb)가 깊은 경로에서 넘치고 접힘 처리가 없음
- 파일: Sources/StorageLensApp/ExploreView.swift
- 원인/근거: ExploreView.swift:59-73은 모든 경로 구성요소를 `Button`의 HStack으로 나열하고 Spacer·크기·재스캔 버튼을 같은 줄에 둔다. 스크롤·말줄임·중간 생략이 없어 깊은 경로나 760 폭에서는 버튼 텍스트가 줄바꿈되거나 잘리며 크기와 재스캔 버튼이 밀린다.
- 영향: 깊은 폴더로 들어갈수록 상위 이동 경로 조작과 현재 폴더 크기 표시가 깨진다.
- 수정 방향: 경로를 가로 스크롤 또는 중간 생략(…) 메뉴로 접고, 크기·재스캔은 고정 영역으로 분리한다.
- 검증 메모: ExploreView.swift:59-73 breadcrumb이 HStack에 모든 구성요소를 나열하고 스크롤·생략 처리가 없음 확인. 깊은 경로에서 레이아웃 압박은 실제이나 SwiftUI가 압축·잘림 처리하므로 깨짐 정도는 미확인(추측 요소), low.

### design-10 [low] 색상 스타일이 화면마다 제각각이고 배지·배너가 중복 구현됨, 소형 색 글씨 대비 우려
- 파일: Sources/StorageLensApp/OverviewView.swift, Sources/StorageLensApp/ExploreView.swift, Sources/StorageLensApp/AppsView.swift, Sources/StorageLensApp/MainView.swift, Sources/StorageLensApp/JournalView.swift
- 원인/근거: 캡슐 배지가 SafetyTag(OverviewView.swift:127, 패딩 6/1), ConfidenceBadge(ExploreView.swift:162, 패딩 5/1), GroupRow.badge(AppsView.swift:212)로 세 번 중복된다. 배너는 RescanBanner `.yellow.opacity(0.15)`(ExploreView.swift:193), BannerStack `.orange.opacity(0.15)`(MainView.swift:62), AppsView 경고 `.orange.opacity(0.12)`(:95), JournalView `.quaternary`(:22)로 모두 다르다. 배지는 caption2(약 10pt) 글씨에 같은 색 18% 배경이라 라이트 모드에서 주황/초록 글씨 대비가 낮다.
- 영향: 시각적 일관성이 떨어지고 작은 색 글씨의 가독성이 낮다. 색에 의존하는 구분은 접근성에도 약하다.
- 수정 방향: 공용 Badge·Banner 컴포넌트를 만들어 크기·색 토큰을 한 곳에서 정의하고, 텍스트 색은 배경 대비를 확보한 시맨틱 색을 쓴다.
- 검증 메모: 배지 3중 복제(SafetyTag 6/1, ConfidenceBadge 5/1, GroupRow.badge 5/1)와 배너 색 불일치 확인. 대비 문제는 정량 근거 없음. 일관성 문제로 low.

### design-11 [low] 선버스트 색상이 다크 모드·접근성을 고려하지 않음
- 파일: Sources/StorageLensApp/SunburstView.swift
- 원인/근거: SunburstView.swift:79는 채도 0.55·밝기 0.95에서 깊이당 0.12씩 낮춘 고정 HSB를, :30은 검정 25% 외곽선을 쓴다. 외모(라이트/다크) 분기가 없고 인접 조각이 색조만으로 구분되며 '기타' 조각은 회색 50%(:74-77)로 배경과 대비가 약하다. `.accessibilityLabel` 등 접근성 코드가 앱 전체에 없고 Canvas는 VoiceOver에 노출되지 않는다.
- 영향: 다크 모드에서 파스텔이 과하게 밝고 외곽선이 거칠며, 색각 이상 사용자나 VoiceOver 사용자는 선버스트를 쓸 수 없다.
- 수정 방향: colorScheme에 따라 밝기·외곽선 색을 조정하고, 접근성 요소(조각 요약 목록 또는 레이블)를 제공해 목록 화면을 대체 경로로 안내한다.
- 검증 메모: SunburstView.swift에 고정 HSB·검정 25% 외곽선, colorScheme 분기 없음, 앱 전체에 accessibility 코드 없음 확인. 다크 모드에서 실제 거칠기는 미확인이나 접근성 부재는 사실.

### design-12 [low] 선버스트 중앙 버튼이 최상위에서도 '위로' 아이콘을 보여주고 누르면 아무 일도 없음
- 파일: Sources/StorageLensApp/SunburstView.swift
- 원인/근거: SunburstView.swift:33-36은 항상 `arrow.up.circle` 아이콘을 표시하고 :63-66의 문구만 '최상위'/'상위로'로 바뀐다. 최상위에서 탭하면 :45 `focusUp()`이 조용히 무시된다. 어포던스와 비활성 상태가 시각적으로 구분되지 않는다.
- 영향: 눌러도 반응이 없는 컨트롤처럼 보인다.
- 수정 방향: 최상위에서는 아이콘을 숨기거나 흐리게 하고, 가운데에 현재 폴더 이름·크기를 표시하도록 바꾼다.
- 검증 메모: 항상 arrow.up.circle 아이콘이며 최상위에서 focusUp은 무반응(문구만 '최상위'), 확인. 사소한 어포던스 문제.

### design-13 [low] 앱 아이콘과 온보딩 후속 동선이 없음(재시작 안내만 있고 재시작 수단 없음)
- 파일: Resources/Info.plist, build-app.sh, Sources/StorageLensApp/RootView.swift
- 원인/근거: Info.plist와 build-app.sh에 아이콘(CFBundleIconFile/icns) 항목이 없다. RootView.swift:61은 '허용 후 앱을 재시작해야 적용됩니다'라고 안내하지만 :69 '다시 확인' 버튼만 있고 재시작 수단이 없다. 같은 파일 :33 `MainPlaceholderView`는 어디서도 쓰이지 않는 잔재 코드다.
- 영향: Dock/Finder에 기본 아이콘이 표시되어 완성도가 낮아 보이고, 권한 허용 후 사용자가 직접 종료·재실행해야 한다.
- 수정 방향: 앱 아이콘을 추가하고, 권한 확인 후 재시작을 돕는 버튼이나 단계별 안내(스크린샷 또는 번호 목록)를 제공한다. 미사용 뷰는 제거한다.
- 검증 메모: Info.plist/build-app.sh에 Icon 항목 없음, RootView의 재시작 안내에 재시작 수단 없음, MainPlaceholderView 미사용 확인(grep으로 정의 외 사용처 없음). 완성도 이슈로 low.

### design-14 [low] 앱별 표에 정렬이 없고 '캐시만 선택'이 한글 문자열 비교에 의존
- 파일: Sources/StorageLensApp/AppsView.swift
- 원인/근거: AppsView.swift:124-153의 Table에는 sortOrder/KeyPathComparator가 없어 열 머리글로 정렬할 수 없고 체크 열의 머리글이 비어 있다(:125). :162는 `locationKind == "캐시" || "개발 도구 캐시"` 한글 리터럴로 선택 대상을 고른다.
- 영향: 항목이 많은 앱에서 큰 순으로 보기 어렵고, 코어의 위치 라벨이 바뀌면 '캐시만 선택'이 말없이 빈 선택이 된다.
- 수정 방향: 크기·수정일·안전도 열에 정렬을 지원하고 전체 선택 체크박스를 머리글에 둔다. 위치 종류는 라벨 문자열 대신 코어가 주는 식별자로 판별한다.
- 검증 메모: AppsView Table에 sortOrder 없고 첫 열 머리글이 빈 문자열, '캐시만 선택'이 locationKind 한글 리터럴 비교(core의 locations 튜플 kind는 문자열 라벨)임 확인. 코어와 리터럴 불일치 시 빈 선택 가능성은 잠재 위험.

기각:
- design-15 긴 목록을 Lazy가 아닌 VStack+ForEach로 그려 PLAN §16.6의 Lazy 원칙과 어긋남 — OverviewView는 VStack이 맞으나 Hugging Face 목록은 모델/데이터셋 수 정도(통상 수십 개 이하)이고 단순 텍스트 행이라 성능 문제 근거가 없음. CleanupSheet 계획 항목도 사용자가 선택한 소수 항목이며 PLAN §16.6의 '큰 목록'에 해당한다는 증거 없음. 실측 근거 없는 추측이라 기각.

## performance

### performance-1 [low] 선버스트 배치가 메인 액터에서 동기 계산됨 (PLAN §16.6 위반)
- 파일: Sources/StorageLensApp/AppModel.swift:198-208, Sources/StorageCore/Session/SunburstLayout.swift:27-48, Sources/StorageCore/Session/ScanOutcome.swift:82-96
- 원인/근거: reloadExplore()는 @MainActor 클래스 안에서 `arcs = o.sunburst(focusPath: path)`(AppModel.swift:201)를 직접 호출한다. 반면 rows는 Task.detached(204)로 넘긴다. sunburst()는 node(at:)로 경로를 따라 내려가며(ScanOutcome.swift:92 `children.first(where:)` 선형 탐색) SunburstLayout.layout이 방문 노드마다 모든 자식을 크기순 정렬(SunburstLayout.swift:33)한다. 디렉터리 노드는 개수 제한이 없어(Scanner.swift:184-191) 자식이 수만 개인 폴더가 최상위 포커스가 될 수 있다. PLAN §16.6(385행)은 '정렬·합계·묶음 계산은 메인 액터 밖'이라고 명시했다. 또 arcs는 동기, rows는 비동기로 갱신되어 포커스 전환 직후 한 프레임 이상 선버스트와 목록이 서로 다른 폴더를 보여준다.
- 영향: 조각 클릭·더블클릭·상위 이동마다 큰 폴더에서 메인 스레드가 정렬 비용만큼 멈춘다(정량 측정은 없음, 정적 분석). 결정(§16.6)과 구현의 불일치이기도 하다.
- 수정 방향: arcs 계산을 rows와 같은 취소 가능한 detached 작업으로 옮기고 두 결과를 한 번에 반영한다. 레이아웃에서는 임계값 미만 자식을 정렬 전에 걸러내거나 부분 선택으로 상위 조각만 정렬한다. 자식 조회는 이름 해시 맵 또는 정렬 이진 탐색을 고려한다.
- 검증 메모: AppModel.swift:201에서 arcs를 메인 액터에서 동기 계산하고 rows만 detached인 것은 확인됨. SunburstLayout.swift:33 정렬도 맞고 §16.6(정렬은 메인 밖)과 불일치. 다만 정렬 대상이 깊이 4 이내 노드뿐이고 비용은 수십 ms 수준 추정이라 medium은 과장. arcs/rows 비동기 불일치는 사실.

### performance-2 [medium] 귀속 규칙 7(nameMatch)이 앱 수 x 미해결 이름 수만큼 정규식을 반복 컴파일
- 파일: Sources/StorageCore/Attribution/Attributor.swift:217-238, Sources/StorageCore/Support/AppIndex.swift:34-38, Sources/StorageCore/Session/StorageSession.swift:78-80
- 원인/근거: nameMatch()는 호출마다 `for app in appIndex.apps`에서 `Self.normalize(app.displayName)`을 다시 계산한다(233-234). normalize는 `range(of: "v?[0-9]+(\\.[0-9]+)*$", options: .regularExpression)`(219)이라 호출마다 정규식을 새로 만든다. 앱 정규화 결과는 미리 계산·캐시되지 않는다. 메모이즈는 경로 단위(75-81)라 같은 이름이 다른 경로에서 나오면 재계산한다. tryIDRules의 `appIndex.app(bundleID:)`도 caseInsensitiveCompare 선형 탐색이며(AppIndex.swift:35-37) 접두 절단 루프(176-184)에서 이름당 여러 번 호출된다. STATUS.md:20 기준 ~/Library 직속 1,433개 중 규칙 3·4로 해소되지 않은 약 400개가 앱 약 440개와 비교된다. 이 계산은 postProcess의 CategoryTotals.compute(StorageSession.swift:78-80)가 호출하며 취소 불가인 '귀속·카테고리 계산 중' 구간(MainView.swift:105-111)에서 단일 스레드로 돈다. 이 구간의 소요 시간은 STATUS.md에 기록되어 있지 않다.
- 영향: 스캔 자체(12초)와 별개로 후처리 단계가 수 초 늘어날 수 있다(추정치, 미측정). 설치 앱이 많은 Mac일수록 악화되고, 이 구간에는 취소 버튼이 비활성이다.
- 수정 방향: Attributor 초기화 시 앱별 정규화 이름과 소문자 번들 ID 사전을 1회 만들어 재사용한다. 정규식은 끝자리 숫자·버전을 떼는 단순 문자열 처리로 대체하거나 정적으로 한 번만 컴파일한다. 후처리 단계별 소요 시간을 STATUS.md에 실측해 기록한다.
- 검증 메모: Attributor.swift:217-238 확인: nameMatch가 호출마다 모든 앱에 normalize(정규식 range(of:.regularExpression))를 재실행하고 캐시가 없음. 이름 수 x 앱 수의 이차 비용 구조는 코드로 입증됨. 소요 시간은 미측정이므로 medium 유지(상한은 추정). '취소 불가' 부분은 직접 확인하지 않음.

### performance-3 [low] 스캔 진행 상태가 고빈도로 갱신되어 상태를 읽는 뷰 전체가 무효화됨
- 파일: Sources/StorageLensApp/AppModel.swift:137-146, Sources/StorageCore/Session/StorageSession.swift:47-49, Sources/StorageCore/Scan/Scanner.swift:200-207, Sources/StorageLensApp/MainView.swift:15
- 원인/근거: Scanner는 항목 1,000개마다 진행 보고를 내보낸다(Scanner.swift:201). 12.3초에 180만 항목이면(STATUS.md:19) 약 1,800회, 초당 약 150회다. 각 보고마다 StorageSession의 pump가 onProgress를 호출하고(StorageSession.swift:48) AppModel은 매번 새 `Task { @MainActor }`를 만들어 `self.state = .scanning(p)`를 대입한다(AppModel.swift:140-143). MainView.body는 `model.isBusy`를 읽는데(MainView.swift:15) 이는 state를 읽으므로 대입이 있을 때마다 body가 무효화된다. 시간 기반 스로틀이나 합치기(coalescing)는 없다. bufferingNewest(1)은 스트림 쪽만 줄일 뿐 Task 생성은 그대로다.
- 영향: 스캔 중 메인 스레드에 갱신 요청이 초당 100회 이상 쌓이고, 사이드바·상세 영역 body가 반복 재평가되어 UI 응답성이 떨어질 수 있다. PLAN §16.6 '스캔 중 UI 멈춤 없음'과 관련된다.
- 수정 방향: 진행 갱신을 100~200ms 간격으로 합쳐 메인 액터에 한 번만 전달한다. 진행 수치(ScanProgress)와 상태 열거(idle/scanning/finishing)를 별도 관찰 속성으로 나눠 isBusy 판독 뷰가 매 틱마다 무효화되지 않게 한다.
- 검증 메모: AppModel.swift:140-143에서 진행 보고마다 Task를 만들어 state를 재대입하고 스로틀이 없음은 확인. 하지만 1000개 단위 보고라 초당 약 150회로 상한이 있고 bufferingNewest(1)로 스트림은 합쳐짐. 체감 멈춤을 보인 근거가 없어 low.

### performance-4 [low] 탐색 목록 행 생성이 무제한이고 행마다 InUse 심볼릭 링크 해석을 수행
- 파일: Sources/StorageCore/Session/ScanOutcome.swift:123-143, Sources/StorageCore/InUse/InUseIndex.swift:19-27, Sources/StorageCore/InUse/InUseIndex.swift:49-57, Sources/StorageCore/Scan/Scanner.swift:184-191
- 원인/근거: 파일은 디렉터리당 200개로 제한되지만 하위 디렉터리는 제한이 없다(Scanner.swift:184-191에서 모두 records에 추가). rows()는 `focus.children.map`으로 모든 자식에 대해 attribution(forPath:)와 `inUse.processes(usingPathPrefix:)`를 호출한다(ScanOutcome.swift:125-131). processes()는 행마다 `URL(fileURLWithPath:).resolvingSymlinksInPath()`(InUseIndex.swift:22, 컴포넌트별 lstat/readlink 계열 시스템 호출)와 `standardizingPath`(NSString 브리징, 51행), `Array(prefix.utf8)`(31행)를 수행한다. 결과는 폴더 방문마다 새로 계산되며 (경로, 정렬) 단위 캐시가 없다. 목록은 전체 배열을 메인에 대입한다(AppModel.swift:206).
- 영향: 자식이 수천~수만 개인 폴더(node_modules, 캐시 샤드 등)에서 행 생성 지연이 선형으로 커지고, 같은 폴더로 돌아올 때마다 반복된다. detached 실행이라 UI는 멈추지 않지만 목록 표시가 늦어진다. 규모는 정적 분석 추정이다.
- 수정 방향: InUse 질의는 보이는 행에 대해서만 지연 수행하거나, 트리 경로는 이미 실경로이므로 심볼릭 링크 해석을 생략할 수 있는지 검토한다. (포커스 경로, 정렬) 결과를 LRU로 캐시하고 매우 큰 목록은 상위 N개 + 나머지 요약 행으로 제한한다. focus가 연속 호출될 때 이전 detached 작업이 계속 도는 점(취소가 대입만 막음)도 개선한다.
- 검증 메모: ScanOutcome.swift:125-131에서 모든 자식에 attribution과 inUse.processes 호출, InUseIndex에서 행마다 resolvingSymlinksInPath 수행 확인. 그러나 detached 실행이라 UI는 멈추지 않고 자식 수만 개 폴더는 드물어 영향은 목록 표시 지연에 한정, low.

### performance-5 [low] Cleaner.measure가 열거로 얻은 속성을 버리고 항목마다 lstat을 반복하며, 계획·실행에서 같은 트리를 여러 번 순회
- 파일: Sources/StorageCore/Cleanup/Cleaner.swift:182, Sources/StorageCore/Cleanup/Cleaner.swift:278-280, Sources/StorageCore/Cleanup/Cleaner.swift:295-299, Sources/StorageCore/Cleanup/Cleaner.swift:369-386
- 원인/근거: measure()는 디렉터리에서 `fs.entries(in:)`로 자식의 크기 속성까지 이미 받아오고도(383) 각 자식마다 `url.appendingPathComponent(k.name)`을 만들어 재귀 호출하며 그 안에서 `fs.attributes(at:)`(lstat)를 다시 호출한다(375). 즉 파일 하나당 URL 할당과 lstat이 중복된다. 계획 단계(182)에서 한 번 순회하고, command 방식 실행은 전/후 두 번 더(278, 280), iCloud 내리기는 전/후(295, 299) 순회한다. 모두 직렬이다. Apps 화면의 '전체 선택'은 항목 수만큼 plan()에서 직렬로 순회한다(Cleaner.swift:63-77). 시트에는 취소 수단이 없다(CleanupSheet.swift:14-15 '계획 수립 중…').
- 영향: 수십 GB·수십만 파일 캐시를 정리 대상으로 고르면 '계획 수립 중'이 길어지고 UI에서 취소할 수 없다. 이 순회는 정확한 크기 재확인이라는 안전 목적이 있어 제거 대상은 아니고 비용만 줄이면 된다.
- 수정 방향: 열거 결과의 FileEntry(이미 크기·링크 수·종류 포함)를 그대로 합산하고 하위 디렉터리만 재귀한다. 선택 항목 여러 개는 동시성으로 측정하고 계획 단계에 취소를 연결한다. 실행 전 측정은 계획 크기와의 차이 확인 목적이 아니면 생략 가능한지 Opus가 판단한다.
- 검증 메모: Cleaner.swift:369-386에서 entries로 속성을 받고도 자식마다 attributes(lstat)를 재호출하는 중복 확인. 안전 목적의 재측정이라 비용만 줄이면 되는 사항이며 시트 취소 부재는 직접 확인하지 않음. 영향은 대용량 정리 시에 한정되어 low.

### performance-6 [low] IconProvider가 뷰 body에서 동기 디스크 접근을 하고 조회 실패를 캐시하지 않음
- 파일: Sources/StorageLensApp/IconProvider.swift:13-37, Sources/StorageLensApp/ExploreView.swift:97-100, Sources/StorageLensApp/AppsView.swift:196
- 원인/근거: IconProvider.image는 @MainActor이며 NodeRowView·GroupRow·DetailPanel의 body에서 호출된다. .appBundle 경로는 첫 호출에서 `NSWorkspace.shared.icon(forFile:)`(16)을, .bundleID는 `urlForApplication(withBundleIdentifier:)`와 `icon(forFile:)`(29-30)을 메인 스레드에서 동기 실행한다. lookupBundle은 성공한 경우만 캐시에 넣는다(31행). 앱 URL을 못 찾으면 `return nil`(29)로 끝나 아무것도 저장하지 않으므로, 설치되지 않은 번들 ID(경로 규칙 19개 중 도구·미설치 앱 등)를 가진 행은 렌더링할 때마다 LaunchServices를 다시 조회한다. 캐시 상한이나 퇴출은 없고 원본 크기의 NSImage를 그대로 보관한다.
- 영향: 앱 목록(약 440개 그룹)을 처음 스크롤할 때 행 진입마다 디스크 I/O가 메인 스레드에서 발생해 끊김이 생길 수 있다. 미설치 번들 ID 행은 이후에도 반복 조회한다. 정량 측정은 없다.
- 수정 방향: 조회 실패도 음성 캐시로 저장한다. 아이콘 로딩을 백그라운드에서 하고 표시 크기(22~32pt)로 축소해 캐시하며, 로딩 전에는 심볼을 보여준다. 캐시에 개수 상한을 둔다.
- 검증 메모: IconProvider.swift:28-31에서 앱 URL을 못 찾으면 nil 반환하고 캐시하지 않음, appBundle 첫 호출은 메인에서 동기 icon(forFile:) 호출 확인. 다만 NSWorkspace 아이콘 조회는 대체로 빠르고 jank 근거는 미측정이라 low.

### performance-8 [low] 스캐너가 상위 200개만 남길 파일의 Node를 전부 만든 뒤 전체 정렬하고, 전 코어를 기본 QoS로 점유
- 파일: Sources/StorageCore/Scan/Scanner.swift:156-180, Sources/StorageCore/Scan/Scanner.swift:17, Sources/StorageCore/Scan/Scanner.swift:27-35
- 원인/근거: process()는 디렉터리의 모든 파일에 대해 Node(name 문자열 포함)를 생성해 배열에 넣고(168-170), 200개 초과 시 `files.sort`로 전체를 정렬한 뒤 나머지를 버린다(175-179). 크기·개수 합계는 이미 루프에서 누적하므로(167) 버려질 파일의 Node 할당은 낭비다. 병렬도는 activeProcessorCount 전체(17행)이고 `Task.detached` 안에서 동기 `run.execute`가 협력 스레드 풀의 스레드 하나를 스캔 내내 점유한다(27-31, concurrentPerform는 110행). QoS 지정은 없다.
- 영향: 스캔은 이미 12초라 체감 영향은 작다. 다만 파일이 많은 디렉터리(캐시 샤드)에서 불필요한 할당과 N log N 정렬이 있고, 전 코어 점유로 스캔 중 UI가 경쟁할 수 있다.
- 수정 방향: FileEntry 단계에서 크기 상위 200개만 부분 선택(힙 등)하고 생존자만 Node로 변환한다. 병렬도를 코어 수-1 이하로 두거나 QoS를 낮추는 것을 검토한다(속도와 UI 응답의 균형은 실측 후 결정).
- 검증 메모: Scanner.swift:168-179에서 모든 파일 Node 생성 후 정렬·절삭 확인, 병렬도 activeProcessorCount 전체(17행)도 확인. 스캔 12초로 체감 영향이 작다고 보고서 스스로 인정, low.

### performance-9 [low] 앱별 화면이 탭 진입마다 그룹을 다시 계산·대입하고 body에서 반복 필터링
- 파일: Sources/StorageLensApp/AppsView.swift:32, Sources/StorageLensApp/AppsView.swift:42-56, Sources/StorageLensApp/AppsView.swift:87, Sources/StorageLensApp/AppsView.swift:126-133, Sources/StorageLensApp/AppModel.swift:174-176, Sources/StorageLensApp/AppModel.swift:355-366
- 원인/근거: AppsView는 onAppear마다 refreshAppGroups()를 호출한다(32). finish()도 같은 호출을 이미 했다(AppModel.swift:175). refreshAppGroups는 appGroupsLoading을 true로 바꾸고 detached 작업 후 appGroups 배열을 통째로 재대입한다(360-364). 값이 같아도 @Observable은 대입 시 알려 List/Table이 다시 그려지고 로딩 문구로 깜빡일 수 있다. body에서는 `filtered`가 두 번 평가되고(55-56) 검색어 입력마다 localizedCaseInsensitiveContains로 전 그룹을 두 번 훑는다. Toggle의 get 클로저는 체크 집합이 없으면 행마다 defaultChecked로 항목 전체 Set을 만든다(126-131, 87).
- 영향: 탭 전환 시 불필요한 재계산·재렌더와 목록 상태 초기화 가능성이 있다. 규모(그룹 수백~천 개)에서는 눈에 띄는 병목은 아니다.
- 수정 방향: 결과가 같은 outcome·실행 앱 집합이면 재계산과 재대입을 생략한다. 필터 결과는 한 번 계산해 재사용하고, 기본 체크 집합은 그룹 선택 시 1회만 만든다.
- 검증 메모: AppsView.swift:32 onAppear마다 refreshAppGroups 호출, finish에서도 이미 호출, 결과를 통째로 재대입(AppModel.swift:355-366) 확인. Toggle get에서 defaultChecked 반복 생성도 확인. 눈에 띄는 병목은 아님, low.

### performance-10 [low] 다중 선택 시 가용성 계산 작업이 저장·취소되지 않고 이전 작업이 계속 실행
- 파일: Sources/StorageLensApp/AppModel.swift:210-224, Sources/StorageCore/Session/CleanupSupport.swift:38-46, Sources/StorageCore/Catalog/Catalog.swift:72-76, Sources/StorageCore/Catalog/Catalog.swift:128-132
- 원인/근거: setSelection은 선택이 바뀔 때마다 `Task { Task.detached { ... } }`를 새로 만들지만 핸들을 보관하지 않아 이전 작업을 취소하지 못한다(217-223). 결과 반영만 `self.selection == paths`로 걸러진다. 각 경로마다 cleanupAvailability가 matcher.match를 호출하는데, match는 항목·패턴마다 expand()로 세그먼트 배열을 새로 만든다(Catalog.swift:74, 128-132). 목록 전체 선택(Cmd-A)이나 연속 Shift 선택에서 수천 경로가 처리될 수 있다.
- 영향: 선택을 빠르게 바꾸면 이전 계산이 끝까지 돌아 CPU를 쓰고, 그동안 '확인 중…' 때문에 정리 버튼이 비활성으로 남는 시간이 늘 수 있다. 카탈로그가 작아(항목 18개, 패턴 21개) 경로당 비용은 작다.
- 수정 방향: 선택 작업 핸들을 보관해 새 선택 시 취소하고, 작업 내부에서 주기적으로 취소를 확인한다. 매처가 패턴을 초기화 시 한 번만 확장해 재사용하게 한다.
- 검증 메모: AppModel.swift:217-223에서 Task 핸들을 보관하지 않아 이전 계산이 취소되지 않음을 확인. 결과 반영만 selection 비교로 걸러짐. 카탈로그가 작아 경로당 비용이 작으므로 low.

### performance-11 [low] 정리 시트 미리보기가 비지연(VStack) 컨테이너로 전체 항목을 즉시 생성
- 파일: Sources/StorageLensApp/CleanupSheet.swift:33-38, Sources/StorageLensApp/CleanupSheet.swift:56-61
- 원인/근거: preview()는 ScrollView 안 VStack에서 `ForEach(Array(plan.items.enumerated()), id: \.offset)`로 모든 계획 항목과 거부 항목을 한 번에 만든다(36행, 거부 목록 57-61행). 항목마다 경고 라벨·배경이 있는 중첩 뷰다. id가 offset이라 계획이 바뀌어도 뷰 재사용이 구분되지 않는다. PLAN §16.6(385)은 '큰 목록은 Lazy 컨테이너'를 요구한다. 앱별 화면의 '전체 선택'은 항목 수백 개를 한 시트로 넘길 수 있다.
- 영향: 항목이 많을 때 시트 표시와 스크롤이 무거워질 수 있다. 일반적인 소수 항목 정리에서는 영향이 없다.
- 수정 방향: LazyVStack 또는 List로 바꾸고, 항목의 안정적인 id(경로)를 사용한다.
- 검증 메모: CleanupSheet.swift:33-38에서 ScrollView+VStack에 ForEach(enumerated, id:\.offset)로 전체 생성, 거부 목록도 동일. PLAN §16.6의 Lazy 컨테이너 요구와 어긋남. 일반 정리는 소수 항목이라 low.

### performance-12 [low] 선버스트 Canvas가 매 그리기마다 색을 선형 탐색으로 재계산하고 조각당 fill+stroke를 두 번 래스터화
- 파일: Sources/StorageLensApp/SunburstView.swift:15-31, Sources/StorageLensApp/SunburstView.swift:68-80, Sources/StorageLensApp/SunburstView.swift:51
- 원인/근거: body 안에서 `topHues(arcs)`를 매번 만들고(16), Canvas 클로저는 조각마다 `color(for:)`를 호출하는데 이 함수는 `hues.first { $0.range.contains(mid) }` 선형 탐색을 한다(76). Path를 조각마다 새로 만들어 fill과 stroke를 각각 그린다(29-30). 조각 수는 0.5% 임계값 덕에 링당 최대 약 200, 합계 최대 약 800개로 제한된다. 창 크기를 끌 때 GeometryReader 때문에 body와 Canvas가 매 프레임 다시 실행된다. 클릭 판정도 `arcs.first(where:)` 선형 탐색이다(51).
- 영향: 조각 상한이 있어 현재는 눈에 띄는 병목이 아니다. 창 크기 조절 중 프레임 비용이 불필요하게 크다.
- 수정 방향: 조각별 색을 SunburstArc 생성 시점 또는 모델에서 한 번 계산해 저장한다. 크기만 바뀌는 경우 Path 재사용이나 drawingGroup을 검토하고, fill과 stroke를 하나의 호출로 합치는 것을 고려한다.
- 검증 메모: SunburstView.swift:16에서 body마다 topHues 계산, Canvas 내 조각당 fill+stroke 확인. 조각 수가 상한(수백)이라 실질 병목 아님. 다듬기 수준 low.

### performance-13 [low] 귀속 캐시가 무제한이고 상속 근거 문자열이 깊이에 비례해 누적
- 파일: Sources/StorageCore/Attribution/Attributor.swift:21, Sources/StorageCore/Attribution/Attributor.swift:75-81, Sources/StorageCore/Attribution/Attributor.swift:101-109
- 원인/근거: cache는 경로 키 딕셔너리로 퇴출 정책이 없다(21, 79). 상속 시 `inherited.rule = "상위 폴더 '...'에서 상속 — \(pa.rule)"`처럼 부모의 rule 문자열을 앞에 덧붙이므로(107) 깊이가 깊어질수록 각 항목의 문자열이 길어진다. 탐색 화면에서 큰 폴더를 열면 모든 자식이 캐시에 쌓인다(ScanOutcome.rows가 자식마다 attribution 호출, ScanOutcome.swift:129).
- 영향: 장시간 탐색 시 메모리가 서서히 늘고, 상세 패널의 '귀속 근거'가 상속 단계 수만큼 길어진다. 규모는 작아 영향은 제한적이다.
- 수정 방향: 상속 근거는 원본 규칙 하나와 상속 깊이로 표현하거나 표시 시점에 조합한다. 캐시에 상한(LRU)을 둔다.
- 검증 메모: Attributor.swift:107에서 부모 rule 문자열을 앞에 덧붙여 깊이만큼 문자열이 누적됨을 확인, 경로 캐시에 퇴출 정책 없음. 영향은 제한적이며 상세 패널의 근거 문구가 길어지는 사용성 이슈에 가까움, low.

### performance-14 [low] 개요 화면 body에서 카테고리 정렬과 도구 탐색(파일시스템 호출)을 메인 스레드로 매번 수행
- 파일: Sources/StorageLensApp/OverviewView.swift:68-95, Sources/StorageCore/Session/CleanupSupport.swift:48-51, Sources/StorageCore/Support/ToolLocator.swift:20-30
- 원인/근거: categorySection(o)는 OverviewView.body 안에서 `categoryTotals.filter{}.sorted{}`(72)와 가상 항목마다 `o.virtualAvailability(e)`(83)를 실행한다. virtualAvailability는 matcher.resolve로 이어져 ToolLocator.locate를 호출하고, locate는 후보 디렉터리 최대 5곳에 대해 fileExists와 isExecutableFile 시스템 호출을 수행한다(ToolLocator.swift:22-28). body는 icloud, volume, rescanRecommended 등이 바뀔 때마다 다시 평가된다.
- 영향: 가상 항목 수가 적어 비용은 작지만, PLAN §16.6의 '계산은 메인 액터 밖에서 1회'와 다르게 메인에서 반복되고 카탈로그 가상 항목이 늘면 선형으로 커진다.
- 수정 방향: 카테고리 정렬 결과와 가상 항목 가용성을 스캔 완료 시(백그라운드) 한 번 계산해 모델에 저장하고 body는 읽기만 한다.
- 검증 메모: OverviewView.swift:72에서 body 안 filter/sorted 확인, ToolLocator.locate가 fileExists/isExecutableFile을 호출하는 것도 확인. 가상 항목 수가 적어 비용은 미미, low.

### performance-15 [low] 하드링크 1회 집계가 스레드 경쟁 순서에 의존해 실행마다 귀속 폴더가 달라질 수 있음
- 파일: Sources/StorageCore/Scan/Scanner.swift:80-82, Sources/StorageCore/Scan/Scanner.swift:161-166, Sources/StorageCore/History/HistoryStore.swift:77-93
- 원인/근거: 여러 워커가 동시에 디렉터리를 처리하며 `seenLinks.insert(...).inserted`가 먼저 성공한 쪽만 크기를 집계하고 나머지는 0으로 만든다(161-166). 어느 경로가 먼저 처리될지는 스레드 스케줄에 달려 있어 실행마다 달라질 수 있다. 전체 합계는 같지만 하드링크 파일이 있는 폴더별 크기(요약의 topFolders)는 달라진다. 이력 비교는 이 폴더 크기를 바탕으로 한다(HistoryDiff.topChanges, HistoryStore.swift:79-83). 하드링크 1회 집계 자체는 PLAN §4(105행) 결정이다.
- 영향: 변화가 없어도 재스캔 간 '증감 상위 10'에 작은 잡음이 섞일 수 있다(하드링크가 많은 Xcode·Homebrew 영역). 큰 오차는 아닐 것으로 추정되며 실측은 없다.
- 수정 방향: 결정 사항(1회 집계)은 유지하되 귀속 폴더를 결정적으로 만드는 방안(예: 스캔 후 경로 순서 기준 재배정)을 Opus가 검토한다. 영향이 미미하면 알려진 한계로 문서화한다.
- 검증 메모: Scanner.swift:161-166에서 병렬 워커의 seenLinks 선점 순서에 따라 하드링크 크기가 귀속되는 폴더가 달라질 수 있음을 확인(1회 집계 결정 자체는 §4 의도). 총합은 동일하고 이력 비교 잡음은 추정이므로 low.

기각:
- performance-7 재스캔 시 이전 결과 트리와 새 스캔 버퍼가 동시에 메모리에 상주하고 노드가 후처리에 불필요한 필드를 모두 보관 — 재스캔 시 메모리 2배는 이론 추정뿐이고 STATUS 실측(0.53GB)은 목표(1.5GB) 이내. Node 필드가 후처리에 쓰이지 않는다는 주장도 '보인다' 수준의 추측으로 직접 입증되지 않음. 근거 불충분.

## safety

### safety-1 [low] command 도구 탐색이 사용자 쓰기 가능 디렉터리를 /usr/bin보다 먼저 봄 (PLAN §8.3과 불일치, FDA 상속)
- 파일: Sources/StorageCore/Support/ToolLocator.swift:11, Sources/StorageCore/Support/ToolLocator.swift:22, Sources/StorageCore/Cleanup/Cleaner.swift:275, Sources/StorageCore/Cleanup/Cleaner.swift:409
- 원인/근거: 후보 순서가 ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, ~/.cargo/bin, /usr/bin이고 첫 실행 가능 파일을 반환한다. PLAN §8.3은 'xcrun은 /usr/bin/xcrun'이라고 명시하지만 구현은 도구별 고정 경로가 없다. 실행 시 같은 경로인지만 비교하고(Cleaner:275) 서명·소유자·해시는 검증하지 않는다. 자식 프로세스는 앱 환경변수를 전부 상속한다(Cleaner:409). 앱은 FDA를 가진 서명 앱이다.
- 영향: ~/.local/bin 등에 같은 이름(xcrun, uv)의 파일이 있으면 시스템 xcrun 대신 그 파일이 정리 버튼 한 번으로 FDA 권한 상속 상태에서 실행된다. 악성 파일뿐 아니라 사용자 래퍼 스크립트가 시스템 도구를 가리는 경우도 같다.
- 수정 방향: xcrun처럼 시스템 도구는 카탈로그나 코어에 고정 절대 경로(/usr/bin/xcrun)를 두고 사용자 쓰기 가능 디렉터리 탐색에서 제외한다. 나머지 도구(uv 등)는 파일 소유자가 root/본인이고 그룹·타인 쓰기 불가인지 확인하고, 정리 시트에 해석된 경로를 이미 보여주므로 비표준 경로일 때 경고를 추가한다.
- 검증 메모: ToolLocator.swift:11,22-27은 ~/.local/bin을 /usr/bin보다 먼저 보고 첫 실행 파일을 반환하며, xcrun 고정 경로는 없어 PLAN:216 문구와 어긋난다. 다만 탐색 순서 자체는 PLAN §8.3 그대로이고, 공격하려면 사용자 쓰기 가능 영역에 같은 이름의 파일을 먼저 심어야 한다. 이 경우 Cleaner:409에서 환경변수가 상속되어 FDA 상속은 사실이지만 현실 가능성이 낮아 low로 낮춘다.

### safety-2 [low] catalog.json 누락·손상 시 비권장(discouraged) 보호가 조용히 해제됨 (fail-open)
- 파일: Sources/StorageCore/Session/StorageSession.swift:28, Sources/StorageCore/Session/StorageSession.swift:34, Sources/StorageCore/Cleanup/Cleaner.swift:99, Sources/StorageLensApp/OverviewView.swift:11, Sources/StorageLensApp/AppModel.swift:128
- 원인/근거: loadResources는 try?로 읽어 실패하면 빈 Catalog를 쓴다. JSON 배열 중 한 항목만 잘못돼도 전체가 빈 카탈로그가 된다. 빈 카탈로그에서는 Cleaner.level이 개인 폴더가 아닌 경로를 모두 review로 판정한다. app-support, containers, preferences, huggingface 같은 discouraged 항목이 확인 체크 없이 실행된다. Cleaner는 카탈로그가 비었는지 검사하지 않는다. 경고는 개요 화면의 주황색 문구 한 줄뿐이고 정리 버튼은 막히지 않는다. 이미 있는 homeMismatch는 fail-closed로 처리한다.
- 영향: swift run이나 번들 밖 실행, 리소스 복사 누락, JSON 한 줄 오류만으로 앱 데이터·컨테이너·설정이 review로 낮춰져 acknowledgedDiscouraged 강제가 무력화된다. 대상은 휴지통으로 가므로 복구는 가능하지만 §16.1 안전 모델이 깨진다.
- 수정 방향: homeMismatch와 같은 방식으로 카탈로그가 비었으면 Cleaner가 plan/execute를 전부 거부하거나, 카탈로그 밖 경로를 전부 discouraged로 올린다. 카탈로그 디코딩은 항목 단위로 실패를 격리하고 오류를 사용자에게 알린다. 리소스 누락 경고를 정리 시트와 앱별 화면에도 표시한다.
- 검증 메모: StorageSession.swift:28-35의 try?는 실패 시 빈 Catalog로 넘어가고, Cleaner.level(:99)은 빈 카탈로그에서 개인 폴더 밖을 review로 판정한다. Cleaner에 카탈로그 비어 있음 검사는 없고 AppModel:128, OverviewView:11 경고만 있다. 코드 근거는 맞다. 다만 정상 번들 배포에서는 발생이 드물고, 대상이 휴지통으로 가서 복구할 수 있어 low로 낮춘다.

### safety-3 [low] .photoslibrary 하위 탐색이 읽을 수 없는 폴더를 건너뜀 (fail-open)
- 파일: Sources/StorageCore/Cleanup/PathSafety.swift:144, Sources/StorageCore/Cleanup/PathSafety.swift:151, Sources/StorageCore/Cleanup/PathSafety.swift:154
- 원인/근거: containsPhotosLibrary는 'guard let kids = try? fs.entries(in: dir) else { continue }'로 열거에 실패한 폴더를 조용히 건너뛴다. 주석에도 '읽을 수 없는 폴더는 건너뛴다'고 적혀 있다. PLAN §16.2는 .photoslibrary가 포함된 상위 폴더 선택을 어떤 확인으로도 거부하라고 한다.
- 영향: 선택한 폴더 아래에 권한 부족(EPERM/EACCES, TCC)으로 열 수 없는 하위 폴더가 있고 그 안에 .photoslibrary가 있으면 탐지 없이 통과한다. 그러면 trashItem이 상위 폴더를 통째로 옮겨 사진 라이브러리까지 휴지통으로 간다. FDA가 없을 때 특히 위험하다. 이 경우를 다루는 테스트는 확인하지 못했다.
- 수정 방향: 열거 실패를 '확인 불가'로 취급해 해당 선택을 거부한다(fail-closed). 사유를 '하위 폴더를 읽을 수 없어 안전 확인 불가'로 표시한다. ENOENT 같은 무해한 오류만 예외로 둔다.
- 검증 메모: PathSafety.swift:151의 try? ... else { continue }는 읽을 수 없는 폴더를 조용히 건너뛰며, 테스트(CleanupTests:185~)에도 이 경우는 없다. 코드 근거는 맞다. 다만 권한 없는 하위 폴더 안에 .photoslibrary가 있는 경우는 드물고 결과는 휴지통 이동이라 복구할 수 있다. low로 낮춘다.

### safety-4 [low] 되돌리기가 휴지통 경로의 이름만 보고 항목 동일성을 확인하지 않음
- 파일: Sources/StorageCore/Cleanup/Cleaner.swift:333, Sources/StorageCore/Cleanup/Cleaner.swift:337, Sources/StorageCore/Cleanup/Cleaner.swift:354, Sources/StorageCore/Cleanup/Journal.swift:4
- 원인/근거: JournalEntry에는 trashPath, size, 시각만 있고 inode/dev가 없다(plan 시점의 inode는 CleanupPlanItem에 있었지만 저널에 기록하지 않음). canUndo는 fs.fileExists(trashPath)와 trash.contains('/.Trash/')만 검사하고 undo는 그 경로를 그대로 moveItem한다. trashPath가 Trash 안의 실제 경로인지(홈의 .Trash 또는 볼륨의 .Trashes 접두) 정규 경로 검사도 하지 않는다.
- 영향: 사용자가 휴지통을 비운 뒤 같은 이름(예: 'foo.txt')의 다른 파일을 휴지통에 넣으면, 옛 기록의 '되돌리기'가 그 다른 파일을 옛 원래 위치로 복원한다. 데이터 유실은 아니지만 잘못된 파일이 복원되고 UI에는 정상 성공으로 보인다. 저널은 사용자 쓰기 가능 파일이라 조작된 경로가 '/.Trash/' 문자열만 포함하면 다른 파일의 이동에 쓰일 수도 있다.
- 수정 방향: trash 성공 기록에 (dev, inode)와 크기를 함께 저장하고, 되돌리기 직전에 휴지통 항목의 lstat 값이 일치할 때만 허용한다(구버전 기록은 비활성). trashPath가 홈 .Trash 또는 해당 볼륨 .Trashes 접두인지 prefix로 검증하고 심볼릭 링크는 거부한다.
- 검증 메모: JournalEntry(Journal.swift:4-14)에는 inode나 dev가 없고, canUndo(Cleaner:333-337)는 경로 존재와 문자열 '/.Trash/' 포함 여부만 검사한다. 코드 근거는 맞다. 다만 휴지통을 비운 뒤 같은 이름의 다른 파일이 같은 휴지통 경로에 들어와야 하므로 조건이 좁고, 데이터가 사라지지는 않는다. low로 낮춘다.

### safety-5 [low] 저널이 손상 줄을 조용히 버리고, 비정상 종료 뒤 다음 기록까지 잃을 수 있음. 인스턴스별 락
- 파일: Sources/StorageCore/Cleanup/Journal.swift:23, Sources/StorageCore/Cleanup/Journal.swift:34, Sources/StorageCore/Cleanup/Journal.swift:43, Sources/StorageCore/Cleanup/Journal.swift:59, Sources/StorageCore/Session/CleanupSupport.swift:77, Sources/StorageCore/Cleanup/Cleaner.swift:355
- 원인/근거: append는 끝에 seekToEnd 후 줄을 쓰는데 파일이 개행 없이 끝나 있는지 확인하지 않는다. 기록 도중 중단된 줄 뒤에 새 줄이 이어 붙어 둘 다 디코딩에 실패한다. entries()는 'compactMap { try? decode }'로 손상 줄을 알림 없이 버린다. 락(NSLock)은 Journal 인스턴스 필드인데 makeCleaner(CleanupSupport:77)와 loadJournal/undo가 호출마다 새 인스턴스를 만든다. 정리 실행과 되돌리기·새로고침이 겹치면 서로 락이 없다. 파일이 없을 때의 .atomic 쓰기는 동시에 만들면 한쪽을 덮어쓴다. undo의 record 실패는 '_ ='로 버려진다(Cleaner:355,359).
- 영향: 휴지통으로 이동은 성공했는데 저널 줄이 사라지면 해당 항목은 앱에서 되돌릴 수 없다(Finder의 '되돌려 놓기'만 가능). 손상 사실이 사용자에게 전혀 표시되지 않는다.
- 수정 방향: Journal을 프로세스 전역 단일 인스턴스(또는 파일 락 flock)로 만들고, append 전에 마지막 바이트가 개행인지 확인해 필요하면 개행을 먼저 쓴다. 한 줄 단위로 O_APPEND 단일 write를 쓴다. entries()가 건너뛴 줄 수를 반환해 '손상된 기록 N건' 배너로 알리고, undo의 저널 오류도 사용자에게 알린다.
- 검증 메모: Journal.swift:43-50은 파일 끝이 개행인지 확인하지 않고 append하며, :59의 compactMap { try? }는 손상 줄을 알림 없이 버린다. 락(:25)은 인스턴스별이다. undo의 record 결과는 Cleaner:355,359에서 버려진다. 코드 근거는 맞다. 다만 쓰기 도중 중단되는 경우가 드물고 영향은 되돌리기 기록 유실에 그쳐 low다.

### safety-6 [low] iCloud 로컬 사본 내리기가 업로드 여부를 코어에서 확인하지 않고, 실패 목록이 무제한
- 파일: Sources/StorageCore/Cleanup/Cleaner.swift:293, Sources/StorageCore/Cleanup/Cleaner.swift:326, Sources/StorageLensApp/ICloudView.swift:89, Sources/StorageLensApp/ICloudView.swift:107, Sources/StorageLensApp/CleanupSheet.swift:128
- 원인/근거: evictWalk는 파일마다 evictUbiquitousItem만 호출하고 ubiquitousItemIsUploaded 등 사전 확인이 없다. '업로드 대기라 실패한다'는 가정은 OS가 거부한다는 데 의존하며, 이 평가에서는 그 동작을 검증하지 못했다. UI는 업로드 대기를 경고 문구로만 알리고(ICloudView:~140) 버튼은 막지 않는다. 하위 폴더 버튼(107)은 컨테이너 단위 조회 결과가 없거나 오래돼도 활성이다. 실패는 CleanupFailure 배열에 개수 제한 없이 쌓이고 CleanupSheet:128이 비지연 ForEach로 전부 렌더링한다.
- 영향: OS가 미업로드 파일을 거부하지 않는 상황이면 클라우드에 없는 유일한 사본이 사라질 수 있다(데이터 손실 가능성, 미검증). 거부하는 경우에도 업로드 대기 파일이 수천 개면 결과 시트가 멈춘 듯 느려진다. 동기 재귀가 협력 스레드를 오래 점유하고 취소도 안 된다.
- 수정 방향: 코어에서 파일별로 업로드 완료·업로드 중 여부를 확인해 미업로드 파일은 내리지 않고 건너뛴다(fail-closed). plan 단계에서 업로드 대기 수를 경고에 포함한다. 실패 목록은 상한(예: 100건)과 '외 N건' 요약으로 줄이고 LazyVStack을 쓴다. evict 순회에 취소 확인을 넣는다.
- 검증 메모: evictWalk(Cleaner:315-327)는 업로드 여부를 확인하지 않고 evictUbiquitousItem만 호출한다. 그러나 OS API는 미업로드 파일의 evict를 에러로 거부하는 것이 문서화된 동작이라 데이터 손실은 추측이다. 확인된 부분은 CleanupSheet:128의 비지연 ForEach와 failures 무제한(UI 성능), 업로드 대기를 경고만 하고 막지 않는 점(ICloudView:~140)이다. 이 부분만 low로 인정한다.

### safety-7 [low] 정리 실행 중 시트 닫힘·중복 시작을 막는 장치가 없고 실행 Task가 추적되지 않음
- 파일: Sources/StorageLensApp/MainView.swift:36, Sources/StorageLensApp/AppModel.swift:266, Sources/StorageLensApp/AppModel.swift:300, Sources/StorageLensApp/AppModel.swift:315, Sources/StorageCore/Cleanup/Cleaner.swift:206
- 원인/근거: .sheet(item:)에 interactiveDismissDisabled가 없다. beginCleanup은 cleanupFlow == nil만 검사하고, confirmCleanup의 Task는 보관·취소되지 않으며 execute는 취소를 확인하지 않는다. 실행 중(.executing)에는 취소·닫기 버튼이 없지만 시스템 기본 시트 닫기를 막는 코드도 없다. 시트가 닫히면 cleanupFlow가 nil이 되어 새 정리를 시작할 수 있다. replan의 Task도 저장·세대 확인이 없다.
- 영향: 이전 정리가 끝나기 전 다른 항목 정리를 시작할 수 있다. 서로 다른 Cleaner/Journal 인스턴스가 병렬로 동작해 같은 경로를 이중 처리하거나 저널이 섞일 수 있다. 앱을 종료하면 일부 항목만 처리된 채 끝난다. 실행 중 시트가 닫히는 경로가 실제로 발생하는지는 코드만으로 확정하지 못했다.
- 수정 방향: 실행 중에는 interactiveDismissDisabled를 켠다. 별도의 isExecuting 플래그로 새 정리 시작을 막는다. 실행 Task를 보관하고, 종료 시도 시 진행 중이면 경고한다. execute 루프에 Task 취소 확인을 넣어 취소 시 남은 항목을 skipped로 기록한다.
- 검증 메모: 코드 전체에서 interactiveDismissDisabled가 검색되지 않고, MainView:36의 .sheet(item:)과 AppModel:266 beginCleanup은 cleanupFlow == nil만 검사한다. confirmCleanup(:300)의 Task는 보관되거나 취소되지 않는다. 코드 근거는 맞다. 실행 중 Esc로 시트가 닫히는지는 정적 코드로 확정할 수 없다.

### safety-8 [medium] plan/execute가 큰 폴더를 여러 번 동기 전체 순회하고 취소·진행 표시가 없음
- 파일: Sources/StorageCore/Cleanup/PathSafety.swift:144, Sources/StorageCore/Cleanup/Cleaner.swift:110, Sources/StorageCore/Cleanup/Cleaner.swift:123, Sources/StorageCore/Cleanup/Cleaner.swift:182, Sources/StorageCore/Cleanup/Cleaner.swift:228, Sources/StorageLensApp/AppModel.swift:289
- 원인/근거: 디렉터리 항목 하나에 대해 verify의 containsPhotosLibrary 전체 순회가 classify에서 최대 2회(110, 경로가 달라지면 123), 크기 측정(182)이 1회 일어나고, execute에서 classify(228)가 다시 1회 이상 돈다. inUse 조회도 있다. 전부 동기 재귀이고 Task 취소를 확인하지 않는다. 계획 단계 UI는 취소 버튼 없이 ProgressView만 보인다(CleanupSheet:15). 다수 선택 시 항목별로 순차 실행된다.
- 영향: DerivedData, Application Support 하위의 수백만 파일 폴더, 컨테이너 등을 선택하면 계획 수립과 실행 직전 재검증이 수십 초에서 수 분 걸린다. 그동안 시트는 닫거나 취소할 수 없는 것처럼 보인다. 실행 직전 재검증이 길면 사용자가 본 크기와 실제 상태가 더 벌어진다.
- 수정 방향: photoslibrary 탐지와 크기 측정을 한 번의 순회로 합치고 plan 결과를 재사용한다. execute 재검증에서는 경로·inode 검사와 상위 컴포넌트 검사 위주로 하고, 하위 순회는 plan 시점 결과에 의존하되 정책을 명문화한다. 계획 단계에 취소 버튼과 항목별 진행 표시, Task 취소 확인을 추가한다.
- 검증 메모: containsPhotosLibrary(PathSafety:144)의 전체 재귀 순회가 classify에서 호출되고, plan 단계와 execute(Cleaner:228)에서 반복된다. measure(:375-390)도 별도 순회다. 모두 동기 처리이고 Task 취소를 확인하지 않는다. 대형 폴더에서 지연된다는 점은 코드상 타당하다. 실제 소요 시간은 측정하지 않았으나 성능과 사용성 항목으로 medium을 유지한다.

### safety-9 [medium] 제조사 토큰 매칭이 같은 제조사의 임의 앱 하나로 귀속하고 그룹 키도 그 앱이 됨
- 파일: Sources/StorageCore/Attribution/Attributor.swift:244, Sources/StorageCore/Attribution/Attributor.swift:246, Sources/StorageCore/Session/AppDataIndex.swift:84, Sources/StorageCore/Session/AppDataIndex.swift:93
- 원인/근거: nameMatch는 폴더 이름의 첫 단어가 4자 이상이고 설치 앱의 vendorToken과 같으면 appIndex.apps.first(where:)로 첫 번째 앱을 선택한다. 앱 목록은 경로 정렬 순서에 의존한다. 반환 Attribution의 bundleID는 그 임의 앱의 번들 ID다. AppDataIndex는 그룹 키로 attr.bundleID를 쓰므로(87) 'Google', 'Adobe', 'JetBrains', 'Microsoft' 같은 공용 제조사 폴더가 특정 앱의 그룹에 합쳐진다. appName만 제조사 이름이다. 그룹 생성 시 앞서 들어온 항목의 appName이 유지된다(93).
- 영향: 공용 제조사 폴더가 설치 앱 중 임의의 하나(예: Chrome)의 데이터로 묶여 크기와 '실행 중' 판정이 왜곡된다. 사용자가 '앱 X 데이터'로 보고 선택한 항목에 다른 앱의 데이터가 포함될 수 있다. 신뢰도는 inferred로 표시되지만 앱별 화면 그룹에는 구분되지 않는다.
- 수정 방향: 제조사 토큰이 여러 앱에 해당하면 특정 앱 번들 ID를 붙이지 않고 '제조사 공용(Google 등)' 별도 그룹 키를 쓴다. 단일 앱일 때만 앱에 귀속한다. 정렬 순서에 의존하지 않도록 결정 규칙을 명시하고 테스트로 고정한다.
- 검증 메모: Attributor:244-246은 appIndex.apps.first(where: vendorToken == fw)로 임의의 첫 앱을 골라 그 bundleID를 귀속시키고, AppDataIndex:87 부근은 bundleID를 그룹 키로 쓴다. 코드 근거는 맞다. 앱 순서는 정렬에 의존하고 여러 앱이 같은 제조사 토큰을 가질 때 왜곡이 생긴다.

### safety-11 [low] 하드링크 1회 집계가 동시성 순서에 따라 달라져 폴더 크기가 실행마다 변동
- 파일: Sources/StorageCore/Scan/Scanner.swift:161, Sources/StorageCore/Scan/Scanner.swift:163, Sources/StorageCore/Scan/Scanner.swift:175
- 원인/근거: linkCount > 1인 파일은 seenLinks에 먼저 넣은 워커의 디렉터리에만 크기가 잡히고 나머지는 0으로 기록된다. 어느 디렉터리가 먼저 처리되는지는 큐(removeLast)와 워커 스케줄링에 따라 비결정적이다. 이 처리는 상위 200개 절단(175) 이전에 일어난다. 따라서 선두로 잡힌 하드링크 노드는 절단되면 omittedBytes로만 남는다.
- 영향: 같은 디스크 상태에서도 스캔 때마다 하드링크가 많은 폴더(예: 패키지 저장소, 스토어형 캐시)의 크기가 다른 폴더로 옮겨 다닌다. 이력 비교(HistoryDiff)와 카테고리 합계에 가짜 증감이 생기고, 하드링크 소유 폴더를 정리해도 공간이 안 빠질 수 있다.
- 수정 방향: 스캔 종료 후 단일 스레드에서 정렬된 경로 순서로 하드링크 소유 폴더를 결정(또는 모든 링크 폴더에 비례 표기)해 결정성을 확보한다. 하드링크 폴더임을 상세 패널에 표시한다.
- 검증 메모: Scanner:161-165에서 seenLinks에 먼저 넣은 워커 쪽 디렉터리에만 크기가 잡힌다. 처리 순서는 큐와 워커 스케줄링에 따라 비결정적이라 코드 근거는 맞다. 영향은 하드링크가 많은 폴더의 크기 변동으로 제한적이다.

### safety-12 [medium] 디렉터리당 상위 200개 파일 절단이 앱별·카테고리 항목 목록과 합계를 과소 집계
- 파일: Sources/StorageCore/Scan/Scanner.swift:175, Sources/StorageCore/Session/AppDataIndex.swift:74, Sources/StorageCore/Session/AppDataIndex.swift:99, Sources/StorageCore/Session/CategoryTotals.swift:80, STATUS.md
- 원인/근거: Scanner는 파일 노드를 디렉터리당 200개로 줄이고 나머지는 omittedBytes에만 남긴다. AppDataIndex.build는 parent.children만 순회해 Preferences·Logs·Saved Application State처럼 파일이 직속 자식인 위치에서 200개 초과분이 누락된다. omittedBytes는 합계에 더하지 않는다. CategoryTotals.descend도 node.children만 따라간다. STATUS.md에 '알려진 한계'로 기록돼 있지만 PLAN §10이나 §14의 범위 제외 결정에는 없다.
- 영향: ~/Library/Preferences에 plist가 수백 개 이상이면 앱별 화면의 '설정' 항목, 앱 총합, 카테고리 합계가 과소 표시되고 일부는 정리 대상으로도 나오지 않는다. 합계는 'other'로 흘러간다.
- 수정 방향: 해당 위치(AppDataIndex.locations)는 직속 파일을 전부 노드로 유지하거나, 별도 경량 집계(앱 ID별 합계)를 스캔 시 계산한다. 최소한 omittedBytes를 그룹 합계와 카테고리에 반영하고 화면에 '일부 파일 생략'을 표기한다.
- 검증 메모: Scanner:171-178은 디렉터리당 파일을 200개로 줄이고 나머지를 omittedBytes에만 남긴다. AppDataIndex:74는 parent.children만 순회한다. STATUS.md:33,40에 알려진 한계로 적혀 있으나 PLAN §10·§14의 범위 제외 결정은 아니다. Preferences에 작은 파일이 많으면 앱별 합계가 과소 집계된다.

### safety-13 [low] 크기 측정·설정 로드 등 try?로 오류가 조용히 0 또는 빈 값이 됨
- 파일: Sources/StorageCore/Cleanup/Cleaner.swift:375, Sources/StorageCore/Cleanup/Cleaner.swift:382, Sources/StorageCore/Cleanup/PathSafety.swift:53, Sources/StorageCore/Session/StorageSession.swift:31
- 원인/근거: measure는 attributes/entries 실패 시 0을 돌려 plan 크기가 과소해진다. PathSafety.identity는 lstat 실패 시 nil이라 inode 기반 보호 경로 비교가 조용히 생략된다(이름 기반 비교는 유지된다). 리소스 로드의 try?도 같은 유형이다. 사용자에게는 오류가 전달되지 않는다.
- 영향: 권한이 부족한 하위 폴더가 있으면 정리 미리보기 크기와 '확보' 계산이 실제보다 작게 나온다. 일부 방어 계층이 오류 시 말없이 약해진다.
- 수정 방향: 측정 중 읽기 실패 건수를 모아 'N개 항목은 크기에 포함되지 않음'으로 표시한다. identity 조회 실패는 보호 경로에 대해서는 거부(fail-closed)로 취급한다.
- 검증 메모: measure(Cleaner:375-390)는 attributes 실패 시 0을, entries 실패 시 빈 목록을 조용히 반환하고, PathSafety.identity(:53)도 try?로 nil을 반환한다. 코드 근거는 맞고 영향은 크기 과소 표시와 보조 방어 약화로 제한적이라 low다.

### safety-15 [low] 스캔 마무리(postProcess) 단계의 취소가 무시되고 결과가 그대로 반영됨
- 파일: Sources/StorageCore/Session/StorageSession.swift:53, Sources/StorageCore/Session/StorageSession.swift:57, Sources/StorageLensApp/AppModel.swift:137, Sources/StorageLensApp/AppModel.swift:156
- 원인/근거: scan()은 결과 확인 후 Task.checkCancellation을 한 번 하고 postProcess를 Task.detached{...}.value로 실행한다. 이 .value는 취소를 전파하지 않고 postProcess 내부에도 취소 확인이 없다. AppModel.cancelScan은 scanTask만 취소하므로 이 단계에서는 취소해도 finish(out)이 호출돼 결과가 적용되고 이력도 저장된다.
- 영향: '마무리 중' 상태에서 사용자가 취소해도 앱색인 구축(Spotlight 최대 4초+), 이력 저장, 휴지통 재스캔이 계속된 뒤 결과가 화면에 나타난다. 취소 의미가 흐려질 뿐 데이터 손상은 없다.
- 수정 방향: postProcess 각 단계 사이에 Task.checkCancellation을 넣고, 취소 후 반환된 결과는 적용하지 않는다. finishing 상태에서의 취소 버튼 동작을 정의한다.
- 검증 메모: StorageSession.swift:53-58은 Task.checkCancellation 이후 postProcess를 Task.detached{}.value로 실행하는데, 이 방식은 취소를 전파하지 않고 내부에도 확인이 없다. 그래서 finishing 상태에서 취소해도 결과가 적용된다. 코드 근거는 맞고 영향은 취소 의미가 흐려지는 정도라 low다.

기각:
- safety-10 고아 추정이 설치 앱 색인의 완전성에 의존하며 discouraged를 review로 낮춤 — 고아 추정 판정은 PLAN §6.1·§16.1에서 결정한 사항이고 발견 항목 스스로 '결정과 어긋나지 않는다'고 적었다. 색인 완전성 한계는 설계 선택이며 새 결함으로 볼 근거가 부족해 제외한다.
- safety-14 차단 목록 밖의 민감 홈 경로(~/.aws, ~/.netrc 등)와 휴지통 자체가 확인 없는 review로 정리 가능 — 카탈로그 밖 경로를 review로 두는 것은 PLAN §16.1에서 결정한 사항이고 deniedRoots도 §16.2 목록 그대로다. 복구 가능한 휴지통 이동이다. ~/.Trash 처리와 테스트 부재는 구체적 오작동 근거가 없어 제외한다.

## a11y-i18n

### a11y-i18n-1 [medium] 선버스트 차트가 VoiceOver에 완전히 숨겨져 있고 키보드로 조작 불가
- 파일: Sources/StorageLensApp/SunburstView.swift
- 원인/근거: SunburstView.swift:19-32 Canvas로 조각을 그리지만 accessibilityLabel/Element/Children 지정이 없다(StorageLensApp 전체에서 accessibility* 사용 0건). 조각 선택은 :42-54 onTapGesture(좌표 계산)뿐이고 focusable/onKeyPress가 없다. 중앙 '상위로' 동작도 탭 좌표 판정(:45)에만 의존한다. 도움말은 :55 .help 툴팁뿐이다.
- 영향: VoiceOver 사용자는 차트의 존재·내용을 알 수 없고, 키보드 전용 사용자는 차트로 확대/상위 이동을 할 수 없다. 탐색 화면의 핵심 시각화이므로 해당 사용자에게는 기능 접근이 막힌다(목록·breadcrumb이 대체 경로이긴 하다).
- 수정 방향: 차트 전체를 접근성 컨테이너로 두고 조각(깊이 1~2 상위 N개)을 이름·크기·비율을 담은 accessibilityElement/children으로 노출하며, 활성화 동작(확대/선택)과 '상위로' 동작을 accessibilityAction으로 제공. 키보드 포커스와 방향키 이동을 지원하거나, 목록 뷰가 동등한 대체 경로임을 라벨로 안내.
- 검증 메모: SunburstView.swift:19-55를 확인했다. Canvas와 onTapGesture뿐이고 앱 전체에서 accessibility*, focusable, onKeyPress 사용이 없다. 다만 같은 탐색 화면의 목록과 breadcrumb이 동등한 대체 경로여서 high는 과장이다.

### a11y-i18n-2 [medium] 앱별 표 체크박스의 라벨이 빈 문자열이라 어떤 항목인지 알 수 없음
- 파일: Sources/StorageLensApp/AppsView.swift
- 원인/근거: AppsView.swift:125-133 Toggle("", ...) .labelsHidden() — 라벨이 빈 문자열이고 접근성 라벨/값도 따로 없다. 이 체크박스가 정리 대상(휴지통 이동/도구 실행) 선택의 유일한 수단이다(:173).
- 영향: VoiceOver는 '체크박스, 선택 안 함'만 읽어 어떤 파일/폴더인지 모른 채 정리 대상을 선택하게 된다. 정리 비권장 항목도 구분 불가여서 안전 관련 오조작 위험이 있다.
- 수정 방향: Toggle의 라벨을 항목 이름(필요하면 위치 종류와 안전도 포함)으로 지정하되 시각적으로만 숨기고(labelsHidden 유지), 접근성 라벨/값에 이름·크기·안전도가 전달되게 한다.
- 검증 메모: AppsView.swift:125-133에서 Toggle("")에 labelsHidden이 붙어 있고 접근성 라벨이 없다. 항목 식별이 불가능하다. 정리 실행 전에 확인 시트가 있어 데이터 손실 위험이 직접 연결되지는 않으므로 high는 과장이다.

### a11y-i18n-3 [low] 안전도·신뢰도·증감·상태 정보가 색 위주로 전달되고 일부는 접근성 텍스트도 불충분
- 파일: Sources/StorageLensApp/OverviewView.swift, Sources/StorageLensApp/JournalView.swift, Sources/StorageLensApp/ExploreView.swift, Sources/StorageLensApp/CleanupSheet.swift
- 원인/근거: OverviewView.swift:107-108 증감은 부호 문자가 있으나 의미(증가/감소)가 색(.red/.green)에 의존해 적록 색약에서 구분이 약하다. VolumeBar(:138-146)는 색 막대로만 사용/정리 가능/여유를 구분하며 범례(:149-151)도 색 점이다. JournalView.swift:70 성공/일부 성공은 텍스트가 있으나 색만 다르다. ExploreView.swift:116 '사용 중'은 circle.fill+초록으로 의미 아이콘이 없다. CleanupSheet.swift:172-177 상태는 텍스트가 있어 보완되지만 SafetyTag/ConfidenceBadge는 캡슐 배경색+텍스트 조합이다.
- 영향: 색각 이상 사용자가 증가/감소, 위험도, 공간 구성 막대를 구분하기 어렵다. 막대는 텍스트 범례가 있어 정보는 있으나 막대 자체는 VoiceOver에 라벨이 없다.
- 수정 방향: 증감에는 방향 아이콘/화살표(증가·감소)를 병기하고, 안전도 태그에는 의미 아이콘(체크/경고/금지)을 추가한다. VolumeBar에는 전체 요약 접근성 라벨(사용·정리 가능·사용 가능 수치)을 달고 장식 요소는 숨긴다.
- 검증 메모: OverviewView.swift:107-108 증감은 부호 문자가 있고 :149-151 범례는 텍스트이며 SafetyTag도 텍스트가 있다. 색 의존은 보조적 수준이다. VolumeBar에 라벨이 없는 점만 실제 결함이다.

### a11y-i18n-4 [low] 아이콘 전용 버튼과 장식 이미지에 접근성 라벨/숨김 처리가 없음
- 파일: Sources/StorageLensApp/ExploreView.swift, Sources/StorageLensApp/SunburstView.swift, Sources/StorageLensApp/DetailPanel.swift, Sources/StorageLensApp/IconProvider.swift
- 원인/근거: ExploreView.swift:69-70 재스캔 버튼은 Image(systemName: "arrow.clockwise")만 있고 라벨은 .help("다시 스캔") 툴팁뿐이다(툴팁은 VoiceOver 라벨을 보장하지 않음). :121-123 iCloud 전용 표시도 아이콘+help뿐. :64 chevron 구분자, SunburstView.swift:34 중앙 아이콘, DetailPanel.swift:12·ExploreView.swift:110의 앱 아이콘은 accessibilityHidden 처리가 없어 불필요하게 읽히거나 이름 없는 이미지로 읽힌다. RootView.swift:55 온보딩 장식 아이콘도 동일.
- 영향: VoiceOver에서 '버튼'만 읽히거나(재스캔) 이름 없는 이미지가 나열되어 목록·상세의 탐색 잡음이 커진다.
- 수정 방향: 아이콘 전용 버튼은 Label 또는 accessibilityLabel로 이름을 부여하고, 순수 장식 이미지(앱 아이콘·구분 chevron·중앙 아이콘)는 접근성에서 숨긴다. 의미 있는 아이콘(iCloud 전용)은 행 요약 라벨에 텍스트로 포함.
- 검증 메모: ExploreView.swift:69-70 재스캔 버튼은 아이콘만 있고 .help만 있다. 장식 이미지의 accessibilityHidden 처리도 없다. 실제이나 영향은 경미하다.

### a11y-i18n-5 [medium] 탐색 목록 행이 하위 요소 단위로 읽혀 요약이 없고, 주요 동작이 더블클릭 제스처에 의존
- 파일: Sources/StorageLensApp/ExploreView.swift
- 원인/근거: ExploreView.swift:95-100 행에 onTapGesture(count: 2)로 폴더 진입을 구현하고 accessibilityAction/accessibilityElement(children: .combine) 가 없다. NodeRowView(:105-136)는 이름·귀속·크기·수정일·배지가 개별 Text로 흩어져 있다. 키보드 대체(Return 등으로 열기)는 코드에 없다.
- 영향: VoiceOver 사용자는 행마다 많은 조각을 순서대로 듣게 되고, 폴더로 들어가는 방법을 제스처로만 알 수 있다. 키보드 사용자는 breadcrumb 버튼 외에 선택 행에서 폴더를 열 수 없다.
- 수정 방향: 행을 하나의 접근성 요소로 결합해 '이름, 크기, 귀속 앱, 수정일, 사용 중/iCloud 전용 여부' 요약을 제공하고, '폴더 열기' accessibilityAction과 키보드 활성화(Return/방향키 오른쪽 등) 동작을 추가.
- 검증 메모: ExploreView.swift:95-100 폴더 진입이 onTapGesture(count: 2)뿐이고 키보드 대체와 accessibilityAction이 없다. 행 요약 결합도 없다. 키보드와 VoiceOver 사용자는 breadcrumb 외에 폴더 진입 수단이 없다.

### a11y-i18n-9 [low] 스캔 진행·완료·실패가 VoiceOver에 알림으로 전달되지 않음
- 파일: Sources/StorageLensApp/MainView.swift, Sources/StorageLensApp/CleanupSheet.swift, Sources/StorageLensApp/AppModel.swift
- 원인/근거: MainView.swift:86-117 스캔 중/마무리/실패 상태는 시각적으로만 바뀌며, AccessibilityNotification.Announcement 등 알림 호출이 코드 어디에도 없다(grep 결과 accessibility 관련 API 0건). TimelineView 경과 시간(:94-97)은 1초마다 갱신되어 읽기 잡음이 될 수 있고, ProgressView에는 value/라벨이 없다(:90). CleanupSheet 완료/실패 전환(:13-22)과 BannerStack 경고(:54-63)도 알림이 없다.
- 영향: VoiceOver 사용자는 스캔 완료·실패, 정리 결과, 저널 저장 실패 배너가 나타났음을 알아채지 못해 수동으로 화면을 훑어야 한다.
- 수정 방향: 스캔 완료/실패, 정리 단계 전환, 새 배너 표시 시 접근성 공지를 보내고, 경과 시간·현재 경로 같은 고빈도 갱신 텍스트는 접근성에서 제외하거나 갱신 빈도를 낮춘다. 진행 표시에 의미 있는 라벨 부여.
- 검증 메모: MainView.swift:86-100 스캔 상태 전환에 접근성 공지가 없고 ProgressView에 라벨도 없다. 사실이나 상태는 화면에 지속 표시되므로 영향은 낮다.

### a11y-i18n-11 [low] 사이드바·키보드 단축키·메뉴 명령이 없어 키보드 탐색 보조가 부족
- 파일: Sources/StorageLensApp/StorageLensApp.swift, Sources/StorageLensApp/MainView.swift
- 원인/근거: StorageLensApp.swift:19-27 Scene에 .commands/CommandMenu가 없고, 앱 전체에서 keyboardShortcut은 CleanupSheet.swift:95 취소 하나뿐이다. 스캔 시작(MainView.swift:130)·재스캔·화면 전환(사이드바 :9-11)·상세 패널 토글에 단축키/메뉴 항목이 없다.
- 영향: 키보드·스위치 컨트롤 사용자는 모든 동작을 Tab 이동과 클릭 수준에 의존한다. 사이드바 전환 단축키(⌘1~5)나 스캔(⌘R)이 없어 효율이 낮다.
- 수정 방향: 스캔 시작/재스캔/취소, 화면 전환, 상세 패널 표시에 대한 메뉴 명령과 표준 단축키를 추가하고 Full Keyboard Access로 모든 버튼에 도달 가능한지 점검.
- 검증 메모: 메뉴 명령과 단축키가 없고 keyboardShortcut은 CleanupSheet.swift:95 하나뿐이다. 다듬기 수준의 사항이다.

기각:
- a11y-i18n-6 overlay 상세 패널이 포커스·읽기 순서·닫기 수단 없이 겹쳐서 표시됨 — overlay 패널은 사용자가 상세 토글로 열고 닫는다(:84-86). 가려진 목록 읽힘과 Esc 부재는 추측성이며 코드로 입증되지 않았다. 별도 이슈로 보기에는 근거가 약하다.
- a11y-i18n-7 고정 폰트 크기·고정 프레임이 많아 Dynamic Type/큰 글꼴 환경에서 잘림 가능 — 시맨틱 폰트를 사용하고 있다. 글꼴 확대 시 잘린다는 주장은 실행 검증 없는 추측이며, 평가자 본인도 환경 의존적이라고 인정했다.
- a11y-i18n-8 배지(캡슐) 텍스트의 대비가 낮을 수 있음 — 대비를 측정하지 않은 추측이다. 배지는 시스템 시맨틱 색을 쓰고 텍스트 레이블이 있다.
- a11y-i18n-10 정리 시트의 기본 버튼/포커스와 위험 경고 구조가 키보드·VoiceOver 관점에서 약함 — CleanupSheet.swift:95-98에서 확인 버튼에 Return을 할당하지 않는 것은 파괴적 동작이라 안전상 타당한 선택이다. 평가자도 인정했다. 나머지 포커스·그룹 주장은 추측이다.
- a11y-i18n-12 한국어 문구 중 단위·조사·복수 처리가 문자열 이어붙이기로 되어 있어 지역화 확장 시 취약 — PLAN.md가 한국어 단일 UI와 ko_KR 고정을 결정했다(§16.6). 평가자도 현재 범위에서 결함이 아니라고 밝혔다.

## code-quality

### code-quality-1 [low] AppModel·UI 로직 테스트 공백 (테스트 타깃이 StorageCore 하나뿐)
- 파일: Package.swift, Sources/StorageLensApp/AppModel.swift, Tests/StorageCoreTests
- 원인/근거: Package.swift:12-14 테스트 타깃은 StorageCoreTests(dependencies: StorageCore)뿐. Tests/에 AppModel·RootView·정리 흐름(startFlow/replan/confirmCleanup/undo/rescanRecommended) 상태 전이를 검증하는 파일이 없음. AppModel은 400줄에 스캔 상태(idle/scanning/finishing/failed), 정리 플로우, 저널, 앱/iCloud 캐시, 배너를 모두 보유(AppModel.swift:130-400). StorageLensApp이 executableTarget이라 @testable 접근도 어려움.
- 영향: 정리·되돌리기 UI 상태 전이(만료 후 replan, undo 후 loadJournal/rescanRecommended, 취소 시 idle 복귀)가 회귀해도 자동 감지 불가. 데이터 삭제 경로의 마지막 계층이 무검증.
- 수정 방향: UI 로직을 라이브러리 타깃(예: StorageLensUI/AppLogic)으로 분리하거나 AppModel의 상태 머신을 순수 타입으로 추출해 테스트 타깃을 추가. 세션/클리너를 프로토콜로 주입해 스캔 취소·실패·정리 확인·undo 성공/실패 전이를 단위 테스트.
- 검증 메모: Package.swift confirms the only test target is StorageCoreTests and StorageLensApp is an executableTarget, so the AppModel state transitions have no tests. The destructive logic lives in Cleaner, which is tested in core, so this is a coverage gap and not a medium-severity defect.

### code-quality-2 [low] 리소스 로드 실패를 조용히 삼킴 + 번들 리소스 선언 없음
- 파일: Sources/StorageCore/Session/StorageSession.swift, Package.swift, build-app.sh
- 원인/근거: StorageSession.swift:30-37 loadResources가 try?로 JSON 파싱 오류를 무시하고 빈 Rules/Catalog 반환(파일 없음과 스키마 오류 구분 불가). Package.swift에 resources 선언이 없고 Bundle.main에 의존, build-app.sh:30-32가 *.json을 복사만 하며 검증 안 함. 오류 사유가 UI의 resourcesMissing(AppModel.swift:128) 불리언 하나로 축약됨.
- 영향: catalog.json에 오타·스키마 변경이 들어가면 빌드·서명까지 성공한 뒤 앱이 런타임에 정리/귀속 기능이 비활성화된 채 실행됨. 원인 진단 정보 없음. swift run 개발 실행에서는 Bundle.main에 리소스가 없어 항상 비어 있음.
- 수정 방향: 로드 결과를 Result/에러 사유 포함 타입으로 반환해 UI에 구체적 사유 표시. build-app.sh에 JSON 구문·필수 키 검증 단계(plutil/jq 또는 swift 검증 모드) 추가. 개발 실행 경로를 위해 SwiftPM resources 선언 또는 환경변수 경로 폴백 검토.
- 검증 메모: StorageSession.swift:30-37 uses try? and returns empty values on a parse error. SessionTests has a missingResourcesGiveEmpty test, so falling back to empty is intentional. The real gap is that the failure reason is lost, and that build-app.sh (:30-32) copies *.json without validating it.

### code-quality-8 [low] HistoryStore 손상·부분 파일 처리 테스트 및 오류 가시성 부족
- 파일: Sources/StorageCore/History/HistoryStore.swift, Tests/StorageCoreTests/HistoryTests.swift
- 원인/근거: HistoryStore.swift:loadEntries가 디코딩 실패 파일을 조용히 nil 처리(compactMap), save()의 오래된 파일 삭제는 try?(:약 52). HistoryTests.swift의 테스트는 testKeeps30/LatestSameRootOnly/MakeDepthLimit/MakeTop200/Diff 5개뿐이고 손상 JSON·빈 파일·스키마 버전 불일치 케이스 없음. ScanSummary에 스키마 버전 필드 없음(ScanSummary.swift 18줄).
- 영향: 손상 파일은 영구히 디렉터리에 남아 매 로드마다 재시도되고(30개 한도에도 포함되지 않음 → 무한 누적 가능), 향후 ScanSummary 필드 추가 시 기존 이력이 전부 조용히 사라짐. 비교 기능이 이유 없이 '이전 스캔 없음'으로 보임.
- 수정 방향: 손상 파일 격리/삭제 정책과 보존 한도 계산에 포함, 스키마 버전 필드와 마이그레이션 규칙 도입, 손상/빈/구버전 파일 테스트 추가, 최소한 디코딩 실패 로그.
- 검증 메모: HistoryStore.swift:66-74 silently skips files that fail to decode. Because retention is computed over loadEntries, corrupt files are never pruned and would accumulate. This only matters if files become corrupt or the schema changes, so the impact is low.

### code-quality-9 [low] Journal 부분 쓰기·동시성 시나리오 테스트 및 내구성 공백
- 파일: Sources/StorageCore/Cleanup/Journal.swift, Tests/StorageCoreTests/CleanupTests.swift
- 원인/근거: Journal.swift:34-47 append가 FileHandle write 후 fsync 없음, 첫 파일 생성은 atomic이지만 이후는 seekToEnd+write. 락은 프로세스 내 NSLock뿐. 손상 줄 건너뛰기만 CleanupTests.swift:545에서 검증하고, 마지막 줄이 개행 없이 잘린 경우·동시 append·대용량 저널은 테스트 없음. entries()는 매번 전체 파일을 읽어 파싱.
- 영향: 크래시 직전 쓰기로 마지막 줄이 잘리면 다음 append가 그 줄에 이어 붙어 두 항목이 모두 손상될 수 있음(개행 보장 없음). 되돌리기 근거 데이터라 영향이 큼. 저널 증가 시 UI 로드 지연.
- 수정 방향: append 전 파일 끝이 개행인지 확인/보정, 필요 시 synchronize 호출. 잘린 마지막 줄·동시 append 테스트 추가. 저널 크기 상한 또는 로테이션 정책을 PLAN에 명시.
- 검증 메모: Journal.swift:34-47 appends with seekToEnd and never checks for a trailing newline, so a truncated last line would be merged with the next entry. A crash during such a small write is unlikely, hence low.

### code-quality-10 [low] 루트의 .build-* 디렉터리 약 1.6GB 잔존
- 파일: .gitignore, (root) .build-M1-T1 .build-M1-T2 .build-M1-T3 .build-M1-T4 .build-M2-T1 .build-M2-T2 .build-V11-T1 .build-V11-T2 .build-perf
- 원인/근거: du -sh 결과: .build-M1-T1 234M, M1-T2 150M, M1-T3 139M, M1-T4 140M, M2-T1 161M, M2-T2 153M, V11-T1 172M, V11-T2 169M, perf 121M (합계 약 1.44GB). .gitignore는 .build-*/ 무시하지만 디스크에는 남음. 서브에이전트 병렬 빌드용 scratch 경로로 추정(추정 한정).
- 영향: 디스크 낭비 및 스토리지 정리 앱 프로젝트에서 모순적 인상. 오래된 빌드 캐시가 혼동 원인.
- 수정 방향: 태스크 종료 시 정리하는 절차를 STATUS/워크플로 규칙에 추가하고, 빌드 scratch를 시스템 임시 경로로 이동. 사용자 승인 후 일괄 삭제.
- 검증 메모: Nine .build-* directories exist in the project root. They are gitignored, so this is only housekeeping and disk waste.

### code-quality-11 [low] build-app.sh 견고성: 하드코딩된 서명 ID, 사전 검증·노타라이즈 부재
- 파일: build-app.sh, Resources/Info.plist
- 원인/근거: build-app.sh:9 SIGN_ID 기본값이 개인 인증서 해시로 하드코딩. 서명 ID 존재 여부(security find-identity) 확인 없이 :33 codesign 실패 시점에야 종료. 리소스 복사(:30-32)는 nullglob이라 JSON이 0개여도 성공. Info.plist 버전이 0.1/1 고정(:11-12)이라 v1.1 산출물과 불일치. entitlements 없이 --options runtime만 사용.
- 영향: 다른 환경/인증서 만료 시 늦은 실패, 필수 리소스 누락 앱이 서명까지 통과(code-quality-2와 결합). 버전 표시가 릴리스 상태를 반영하지 못함.
- 수정 방향: 스크립트 초입에서 서명 ID 유효성·필수 리소스 존재(catalog.json, attribution-rules.json, Info.plist) 검사. 서명 ID는 환경변수 필수화 또는 설정 파일 분리. 버전 문자열을 한 곳에서 주입.
- 검증 메모: build-app.sh:9 hardcodes the signing-identity hash and runs no pre-check on it. Info.plist:11-12 still has version 0.1 and build 1. Both confirmed. Minor, since this is a personal build script.

### code-quality-12 [low] 테스트 헬퍼 중복 (리소스 경로 해석을 파일마다 복제)
- 파일: Tests/StorageCoreTests/CatalogTests.swift, Tests/StorageCoreTests/AppDataTests.swift, Tests/StorageCoreTests/AttributionTests.swift, Tests/StorageCoreTests/CleanupTests.swift, Tests/StorageCoreTests/SessionTests.swift, Tests/StorageCoreTests/SessionE2ETests.swift
- 원인/근거: #filePath에서 deletingLastPathComponent를 반복해 Resources/catalog.json 경로를 구성하는 코드가 CatalogTests.swift:12-15, AppDataTests.swift:26, CleanupTests.swift:114, SessionTests.swift:23·152 등 최소 5곳에 복제. FixedClock 같은 목도 파일별 private 정의(CatalogTests.swift:5).
- 영향: 리소스 위치가 바뀌면 여러 곳 수정 필요, 테스트 간 불일치 위험.
- 수정 방향: 공용 TestSupport.swift에 리소스 로더·FixedClock·임시 홈 생성 헬퍼를 모으고 각 스위트가 재사용.
- 검증 메모: FixedClock is defined privately in AttributionTests, CatalogTests and SessionTests, so the duplication is confirmed. It is a test-maintenance nit.

기각:
- code-quality-3 Resources JSON 스키마 검증 테스트가 얕음 — I did not grep the tests for global invariants such as id uniqueness or regex validity, so the absence claim is unverified. Per the uncertainty rule this is marked not real.
- code-quality-4 디렉터리당 상위 200 파일 한계가 앱별 합계·귀속 정확도에 미치는 범위 — The 200-file cap is a deliberate decision at PLAN.md:110 and a known limitation in STATUS.md. The claim that the UI may not show it is wrong. ScanOutcome.swift:136-138 adds a 'small files N' row with omittedBytes, SunburstLayout.swift:31 adds an 'other' slice, and ICloudInventory.swift:56 counts omittedFileCount. Directory totals are preserved.
- code-quality-5 ProcessLister 컴파일 경고 원인 및 libproc 호출 구조 — The compiler warning text was never confirmed. The pid x fd loop in ProcessLister.swift:42-66 is real, but its cost is speculation with no measurement behind it.
- code-quality-6 Cleaner.swift 433줄: 계획·실행·undo·측정·프로세스 실행 혼재 — This is a file-structure preference and not a defect. There is no concrete failure scenario.
- code-quality-7 AppModel 400줄 단일 @MainActor 클래스에 다중 책임 — The Task per progress callback at AppModel.swift:140-142 exists, but the state-guarded updates are cheap. The decomposition suggestion is a style preference with no demonstrated problem.
- code-quality-13 광범위한 try? 사용으로 오류 가시성 낮음 — The 44 try? uses are confirmed, but the claim of no logging is wrong because Dataless.swift:4 uses os Logger. The finding does not name concrete cases where silenced errors cause harm.
- code-quality-14 IconProvider·Format 등 UI 유틸의 비테스트·전역 가변 캐시 — The IconProvider cache is unbounded (IconProvider.swift:7), but its keys are limited to installed apps, so growth is negligible. This is not a real problem.
