# StorageLens — 개발 계획서 (PLAN)

작성: Opus (계획 단계) · 2026-10-28 · 프로젝트: StorageLens (가칭)
개정: 2026-10-28 (구현 전 최종 검토) — 귀속 규칙 순서 재배치·퍼지 매칭 구체화, 고아 판정 강화, dataless 파일 다운로드 방지, GUI 앱 PATH 문제, 휴지통≠공간 확보 UX, 카탈로그 우선순위 규칙, HF 캐시 읽기 전용 전환, TM 스냅샷 삭제 v2 이관, 실행 직전 재검증(TOCTOU), Info.plist·서명 ID 지정, 결정 사항 표(§14) 신설
대상: 이 Mac 전용 개인용 macOS 앱. App Store·공증 배포는 범위 밖.

이 문서의 목적: Sonnet이 설계 판단 없이 구현만으로 완주할 수 있는 작업 목록 제공. 문서에 없는 판단이 필요하면 구현 멈추고 `STATUS.md`의 "Opus 확인 필요"에 기록.

---

## 1. 목적과 범위

### 1.1 목적
Mac 저장공간(특히 "시스템 데이터"로 뭉뚱그려지는 캐시·앱 데이터·숨김 폴더)의 분포를 한눈에 보여주고, 각 항목을 **사용하는 프로그램 이름**과 함께 표시하며, 안전하다고 확인된 항목만 정리한다.

### 1.2 v1 범위 안
- Data 볼륨 전체 **스캔**(읽기), 할당 크기 기준 집계
- 선버스트 시각화 + 카테고리별 목록
- **프로그램 귀속(attribution)**: 각 폴더·파일 옆에 앱 이름·아이콘·신뢰도 표시 (§5)
- "사용 중" 표시(열린 파일), 마지막 사용 시점
- 삭제된 앱의 잔여 데이터(고아 추정) 탐지
- 다운로드 파일의 출처 앱·URL 표시
- 정리: **홈 디렉터리 하위만**, 휴지통 이동 또는 도구 자체 정리 명령, 미리보기 필수 (v1.1: 비권장 항목도 개별 확인 후 수동 정리 가능, §16)
- 정리 저널 + 휴지통에서 되돌리기
- 스캔 요약 이력 → "지난 스캔 대비 증가량"
- 전체 디스크 접근(FDA) 권한 안내 화면
- iCloud Drive 로컬 사본 내리기(evict)

### 1.3 v1 범위 밖 (§10)
- root 소유 경로 정리(권한 상승 도우미)
- 로컬 Time Machine 스냅샷 **삭제**(root 필요). v1은 목록·크기 표시만
- Hugging Face 모델 개별 **삭제**(§6.3). v1은 표시만
- 중복 파일 찾기, 예약 스캔·알림, 메뉴 막대, CLI

### 1.4 실측 근거 (2026-10-28, 이 Mac)
- macOS 27.2, Xcode 27.2, Swift 6.4, 서명 ID 1개 유효: `422125C67A778CB23480AFBFE25A0EB7B8C91902` "Apple Development: … (Y847SQVUJ2)"
- Data 볼륨 436GB 사용, inode 약 250만, 로컬 TM 스냅샷 0개
- `~/.cache` 51G(huggingface 40G, uv 7.3G, codex-runtimes 3.3G), `~/Library/Mobile Documents` 26G, `~/Library/Application Support` 25G(Claude 15G), `~/Library/Caches` 18G(Adobe Camera Raw 8.7G)
- `~/Library/{Caches,Application Support,Containers}` 항목 1,239개 중 번들 ID 정확 일치 128, `com.apple.*` 971, 사람 이름 155
- 도구 위치: `uv` → `~/.local/bin/uv`, `brew`·`pip3` → `/opt/homebrew/bin`
- FDA 없는 프로세스에서 `~/Library/Safari` 접근 시 `Operation not permitted` 확인. `~/Library/Application Support/com.apple.TCC`는 이 macOS에 **없음**(흔히 쓰는 TCC.db 검사법 사용 불가)
- HF 캐시는 표준 구조 아님: `hub/blobs/<2자리>/…`에 공유 저장소(17G, `.huggingface-shared-blobs` 마커, `.refs` 파일)가 있고, 모델 폴더의 `blobs/` 파일은 79바이트짜리 포인터. → §6.3

---

## 2. 기술 결정 (확정)

| 항목 | 결정 | 이유 |
|---|---|---|
| 언어/UI | Swift 6 (strict concurrency), SwiftUI, 최소 macOS 26.0, UI 문구 한국어 | 기존 프로젝트와 동일 |
| 빌드 | SwiftPM 패키지 + `build-app.sh`로 .app 조립 | NowPlayingBar 방식 재사용 |
| 서명 | `codesign --force --options runtime --sign "$SIGN_ID"`, `SIGN_ID` 기본값 = §1.4 SHA-1. 애드혹(`-`) **금지** | FDA 허용은 서명 요구사항에 묶임. 애드혹은 빌드마다 바뀌어 재허용 필요 |
| 샌드박스 | 사용 안 함 | |
| 번들 ID | `com.kimmingyu.StorageLens` | |
| 외부 의존성 | 없음 | |
| 크기 기준 | 할당 크기 | sparse·dataless 파일에서 논리 크기는 틀림 |
| 크기 표기 | `ByteCountFormatter`, `.file` 스타일(10진, Finder와 동일) | |
| dataless 파일 | 앱 시작 시 `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)` | 스캔·xattr 읽기가 iCloud 다운로드를 유발하지 않게 |

### 2.1 패키지 구조
```
storage-lens/
  Package.swift              # swift-tools-version 6.0
  Sources/
    StorageCore/             # UI 없는 로직 전부 (테스트 대상)
      Scan/  Attribution/  Catalog/  InUse/  Cleanup/  History/  Support/
    StorageLensApp/          # SwiftUI 앱
  Resources/
    Info.plist
    catalog.json
    attribution-rules.json
  Tests/StorageCoreTests/
  build-app.sh
  STATUS.md                  # Sonnet이 M0-T1에서 생성
```
- 파일시스템·프로세스·시간 접근은 `Support/`의 프로토콜(`FileSystem`, `AppIndex`, `ProcessLister`, `Clock`)로 추상화해 테스트에서 주입.

### 2.2 Info.plist 필수 키
`CFBundleIdentifier`, `CFBundleName`=StorageLens, `CFBundleExecutable`, `CFBundlePackageType`=APPL, `LSMinimumSystemVersion`=26.0, `NSDesktopFolderUsageDescription`·`NSDocumentsFolderUsageDescription`·`NSDownloadsFolderUsageDescription`·`NSRemovableVolumesUsageDescription`(문구: "저장공간 분석을 위해 폴더 크기를 읽습니다").

---

## 3. 화면 구성 (StorageLensApp)

1. **온보딩**: FDA 검사 = `~/Library/Safari` 디렉터리 열기 시도. 성공 → 허용, EPERM → 미허용, 폴더 없음 → `~/Library/Mail`로 재시도, 둘 다 없음 → "확인 불가"(스캔 허용). 미허용 시 시스템 설정 열기 버튼(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) + 재검사 버튼 + "허용 후 앱 재시작 필요" 안내. 미허용이어도 부분 스캔 허용.
2. **개요**: 볼륨 막대(사용 / 사용 가능 / 정리 가능 = `volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity`), 카테고리 합계, 지난 스캔 대비 증감 상위 10, "휴지통 N GB — 비우기 전까지 공간 확보 안 됨" + Finder 휴지통 열기 버튼.
3. **탐색**: 좌측 선버스트, 우측 목록. 목록 행 = 아이콘 · 이름 · 크기 · **프로그램 이름 + 신뢰도 배지(정확/추정/알 수 없음)** · 사용 중 표시 · 수정일. 정렬: 크기/수정일.
   - 선버스트: 깊이 최대 4단계, 전체의 0.5% 미만 조각은 "기타"로 합침, 클릭 시 해당 폴더로 확대.
4. **상세 패널**: 전체 경로, 귀속 근거(어느 규칙인지 한 줄), 다운로드 출처(행 선택 시 지연 조회), Finder에서 보기.
5. **정리 시트**: 미리보기(경로·크기·방법·경고) → 확인 → 실행 → 결과. 휴지통 방식이면 결과에 "휴지통을 비워야 공간이 확보됩니다" 고정 표시.
6. **정리 기록**: 저널 목록, 되돌리기.

UI는 StorageCore의 공개 API만 사용. UI 안에 파일시스템 로직 금지. 앱이 직접 휴지통을 비우는 기능은 **만들지 않는다**(영구 삭제는 사용자가 Finder에서).

---

## 4. 스캐너 (Scan)

- 루트: `/System/Volumes/Data` (사용자가 하위 경로 지정 가능). `/System` 봉인 볼륨 제외.
- 열거: `getattrlistbulk` 자체 구현, 버퍼 256KB. 디렉터리 단위 작업 큐, 동시성 = `ProcessInfo.activeProcessorCount`.
- 수집 속성: 이름, 종류, 할당 크기(`ATTR_FILE_ALLOCSIZE`), 논리 크기, inode(`ATTR_CMN_FILEID`), 링크 수, 수정 시각, 플래그(`ATTR_CMN_FLAGS`, `SF_DATALESS` 판별), 소유 uid.
- 규칙:
  - 심볼릭 링크 **따라가지 않음**(링크 자체 크기만)
  - 마운트 경계 넘지 않음(`st_dev`/`ATTR_CMN_DEVID` 비교)
  - 하드링크(nlink>1)는 (dev, inode) 집합으로 1회만 집계
  - dataless 파일은 할당 크기 0으로 집계, 노드에 `isDataless` 표시
  - APFS clone은 구분 불가 → 각자 집계. UI 도움말에 "복제 파일은 실제보다 크게 보일 수 있음"
  - EPERM/EACCES는 건너뛰고 `skipped`에 경로 기록
  - 접근 시각(atime)은 수집·사용하지 않음(신뢰 불가)
- 출력: 디렉터리 트리 전체 + 디렉터리별 **크기 상위 200개 파일**만 파일 노드 유지, 나머지는 합계에만 반영.
- 진행 보고: `AsyncStream<ScanProgress>`(항목 수, 바이트, 현재 경로), 취소 지원.
- **성능 목표**: 이 Mac Data 볼륨 전체 60초 이내, 최대 메모리 1.5GB 이하. 미달 시 Opus 확인.

## 5. 프로그램 귀속 (Attribution)

출력: `Attribution { appName, subtitle?, bundleID?, iconSource, confidence(.exact/.inferred/.unknown), rule: String, isOrphanSuspect: Bool }`

### 5.1 설치 앱 색인 (스캔 시작 시 1회)
- `NSMetadataQuery`(`kMDItemContentType == com.apple.application-bundle`), 실패·0건이면 `/Applications`, `/Applications/Utilities`, `~/Applications`, `/System/Applications` 직접 열거(깊이 2)
- 각 앱: 번들 ID, 표시 이름, 제조사 토큰(번들 ID 2번째 세그먼트), `kMDItemLastUsedDate`
- 추가 "알려진 ID" 집합(고아 판정 제외용): `/Library/LaunchAgents`, `/Library/LaunchDaemons`, `~/Library/LaunchAgents`의 plist 파일명(확장자 제외)과 `Label`, 실행 중 앱 번들 ID(`NSWorkspace.runningApplications`)

### 5.2 규칙 (위에서 아래로, 먼저 맞는 것 채택)
1. **경로 규칙 표**: `attribution-rules.json`의 경로 패턴 일치(가장 긴 패턴 우선). 예: `~/.cache/huggingface` → "Hugging Face 라이브러리", `~/.cache/uv` → "uv", `~/Library/Caches/Homebrew` → "Homebrew", `~/Library/Caches/ms-playwright` → "Playwright", `~/Library/Developer/Xcode/DerivedData` → "Xcode", `~/Library/Mobile Documents` → "iCloud Drive". CLI 도구는 §8.3 경로 탐색으로 설치 여부를 부제에 표시. `.exact`
2. **Containers 메타데이터**: `~/Library/Containers/<x>/.com.apple.containermanagerd.metadata.plist`의 `MCMMetadataIdentifier` → 이후 3~5를 그 ID로 수행. 읽기 실패 시 폴더 이름 사용
3. **번들 ID 정확 일치** → 해당 앱. `.exact`
4. **Apple 시스템**: `com.apple.` 접두 → "macOS 시스템", 데몬 사전(`attribution-rules.json`)에 있으면 부제. `.exact`. 고아 판정 **대상 아님**
5. **접두 절단**: 마지막 세그먼트를 하나씩 잘라 3 재시도, 세그먼트 2개 남으면 중단(`com.anthropic.claudefordesktop.ShipIt` → Claude). `.inferred`
6. **Group Containers**: `group.` 접두 또는 10자 대문자·숫자 팀 ID 접두(`ABCDE12345.`) 제거 후 3~5. `.inferred`
7. **이름 매칭**(사람 이름 폴더): 정규화 = 소문자화, 공백·`-`·`_` 제거, 끝의 숫자·버전(`2`, `v3`, `-2024`) 제거. 다음 중 하나면 일치:
   - 정규화 폴더명 == 정규화 앱 표시 이름
   - 정규화 폴더명이 정규화 앱 표시 이름으로 시작하거나 그 반대이고, 짧은 쪽 길이 ≥ 5
   - 폴더명 첫 단어(정규화) == 앱 제조사 토큰이고 길이 ≥ 4 (`Adobe Camera Raw 2` → adobe) → appName = 제조사 대표 이름(해당 제조사 앱 중 첫 번째의 제조사 표기), subtitle = 원래 폴더명
   - 후보가 여러 개면 표시 이름이 가장 긴 것. `.inferred`. 편집 거리 등 그 외 유사도 **사용 금지**
8. 그 외 → `.unknown`

- **상속**: 귀속 결과 없는 경로는 가장 가까운 귀속된 상위 폴더 결과 상속. 홈 직속 `Documents`·`Desktop`·`Downloads`·`Pictures`·`Movies`·`Music` 하위는 "사용자 파일".
- **고아 추정**(`isOrphanSuspect`): 아래 **모두** 만족
  - 이름이 역DNS 형태(점 2개 이상)이며 규칙 3·5·6 모두 실패
  - `com.apple.` 아님, 규칙 표에 없음, "알려진 ID" 집합에 접두 일치 없음
  - 설치 앱(§5.1) 중 같은 제조사 접두(역DNS 앞 2세그먼트, 예 `com.mathworks`)를 가진 앱 없음, 그리고 폴더 이름에 설치 앱 번들 ID가 부분 문자열로 포함되지 않음(`bugsnag-shared-com.goodsnooze.vivid`)
  - 위치가 `~/Library/{Caches,Application Support,Containers,Group Containers,Preferences,Logs,HTTPStorages,WebKit,Saved Application State}` 직속
  - 폴더 수정일이 30일 이상 지남
  - 사용 중(§7) 아님
  - 신뢰도는 항상 `.inferred`. UI 문구는 "삭제된 앱의 데이터로 **추정**"
- 결과는 경로별 메모이즈.

### 5.3 다운로드 출처 (지연 조회)
- `com.apple.quarantine` xattr의 agent 필드 → 다운로드한 앱, `kMDItemWhereFroms` → URL
- 스캔 중에는 읽지 않음. 상세 패널 열 때만 조회

## 6. 카테고리 카탈로그 (Catalog)

### 6.1 스키마
```
{ id, title, pathPatterns[], excludePatterns[], minAgeDays?, 
  safety: "safe"|"review"|"never",
  method: "trash"|"command"|"icloudEvict"|"none",
  command?: { tool, args[] }, regenerates: bool, note }
```
- 패턴: `~` 확장, `*`는 한 경로 세그먼트만.
- **우선순위**: 한 경로에 여러 항목이 맞으면 가장 구체적인 패턴 적용. 비교 순서: ① 리터럴(와일드카드 아닌) 세그먼트 수 많은 쪽 ② 전체 세그먼트 수 많은 쪽 ③ 리터럴 문자 수 많은 쪽 (예: `~/Library/Caches/pip`이 `~/Library/Caches/*`를 이김). 단 §5.2 고아 추정이면 `orphan` 항목이 `never`를 포함한 모든 항목보다 우선.

### 6.2 v1 항목 (Sonnet은 이 목록만. 추가·변경은 Opus 확인)

| id | 경로 | 제외 | safety | method |
|---|---|---|---|---|
| user-caches | `~/Library/Caches/*` | `com.apple.*` | safe | trash |
| apple-caches | `~/Library/Caches/com.apple.*` | | review | trash |
| user-logs | `~/Library/Logs/*` | | safe | trash |
| homebrew | `~/Library/Caches/Homebrew/downloads` 하위 항목 | | safe | trash |
| pip | `~/Library/Caches/pip` | | safe | trash |
| uv | `~/.cache/uv` | | safe | command `uv cache clean` (도구 없으면 method none) |
| playwright | `~/Library/Caches/ms-playwright/*` | | review | trash |
| xcode-derived | `~/Library/Developer/Xcode/DerivedData/*` | | safe | trash |
| xcode-sim-unavailable | (경로 없음, 가상 항목) | | safe | command `xcrun simctl delete unavailable` |
| icloud-local | `~/Library/Mobile Documents` 하위 파일 | | review | icloudEvict |
| downloads-old | `~/Downloads/*`, minAgeDays 90 | | review | trash |
| huggingface | `~/.cache/huggingface` | | never | none (§6.3) |
| app-support | `~/Library/Application Support/*` | | never | none |
| containers | `~/Library/Containers/*`, `~/Library/Group Containers/*` | | never | none |
| orphan | 고아 추정 항목 | | review | trash |

- `safe`: 일괄 선택 가능. `review`: 개별 선택만 + 경고. `never`: 정리 버튼 비활성.
- 카탈로그에 없는 경로 = 직접 선택 정리만(`review` 취급), §8.1 금지 경로는 불가.
- `icloudEvict`: 파일 단위 `FileManager.evictUbiquitousItem`. 업로드 안 된 파일은 실패 → 결과에 "업로드 대기"로 표시. 폴더 선택 시 하위 파일 순회. 원본 삭제 아님(클라우드 유지).

### 6.3 Hugging Face (v1 읽기 전용)
- 이 Mac의 HF 캐시는 공유 blob 저장소(`hub/blobs`) + 모델별 포인터 구조라, 모델 폴더만 휴지통으로 옮기면 공간이 거의 안 빠지고 다른 모델이 깨질 수 있음.
- v1: `hub/models--*`, `hub/datasets--*`를 목록으로 표시(이름 = `models--a--b` → `a/b`), 공유 저장소 `hub/blobs` 크기 별도 표시, 각 모델 폴더 수정일 표시. 모델별 실제 크기 계산·삭제는 v2(구조 명세 후).
- UI 안내: "모델 정리는 `hf cache` 명령 또는 각 앱에서".

## 7. 사용 중 탐지 (InUse)

- `proc_listallpids` → pid별 `proc_pidinfo(PROC_PIDLISTFDS)` → vnode fd마다 `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` → 경로. 권한 오류 pid는 건너뜀(내 uid만 보임).
- 결과: 경로 → [프로세스 이름]. 경로 접두 질의 지원(폴더 하위에 열린 파일 있음 판정).
- 시점: 스캔 완료 후 1회 + 정리 시트 열 때 재조회.
- 대상이 사용 중이거나 귀속 앱이 실행 중이면 정리 시트에 "앱 종료 후 정리 권장" 경고. 차단은 안 함.

## 8. 정리 실행 (Cleanup)

### 8.1 안전 규칙 (위반 시 거부, 테스트로 고정)
- 대상은 `realpath` 결과가 **홈 디렉터리 하위**여야 함. 경로 중간에 심볼릭 링크가 있으면 거부.
- 거부 목록(그 자체 및 하위 trash 전부): `~` 자체, `~/Library` 자체, `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Photos`, `~/Library/Mobile Documents`(evict만 허용), `~/.ssh`, `~/.gnupg`, `~/.cache/huggingface`
- 위 거부 목록의 **상위 폴더**도 거부(예: `~/Library` 하위 전체를 담은 선택).
- 삭제 수단은 `FileManager.trashItem`만. `rm`·`unlink`·`removeItem` 금지.
- `command`는 §8.3으로 찾은 절대 경로 실행 파일을 `Process`로 직접 실행(셸 금지), 타임아웃 10분, 전후 대상 크기 측정.
- API는 `plan(selection) -> CleanupPlan` → `execute(plan)` 2단계. `CleanupPlan`은 `plan()`만 생성 가능(외부 init 불가), 생성 후 10분 지나면 만료.
- **실행 직전 재검증**: 항목마다 경로의 (dev, inode)가 plan 시점과 같은지, 여전히 안전 규칙 통과하는지 다시 확인. 다르면 그 항목만 건너뛰고 결과에 기록.

### 8.2 저널
- `~/Library/Application Support/StorageLens/journal.jsonl`: 시각, 원래 경로, 휴지통 경로(`trashItem`의 resultingItemURL), 크기, 방법, 결과.
- 되돌리기: 휴지통 경로 존재 + 원래 경로 비어 있음 + 부모 폴더 존재일 때만 `moveItem`. 아니면 버튼 비활성 + 이유 표시.

### 8.3 CLI 도구 경로 탐색
GUI 앱은 셸 PATH를 상속하지 않음. 도구는 다음 순서로 실행 파일 존재 확인: `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `/usr/bin`. `xcrun`은 `/usr/bin/xcrun`. 없으면 해당 항목 method none + "도구 없음" 표시.

## 9. 이력 (History)
- 스캔마다 요약(카테고리별 합계, 깊이 3까지 폴더 중 크기 상위 200개, 시각)을 `~/Library/Application Support/StorageLens/history/<ISO8601>.json`에 저장, 최근 30개 유지.
- 증감 비교는 같은 스캔 루트끼리만.

---

## 10. v2 후보 (지금 구현 금지)
- 권한 상승 도우미로 `/Library/Caches`, `/private/var/folders`, TM 스냅샷 정리
- HF 캐시 구조 명세 후 모델별 크기·삭제, 모델 ↔ 사용 프로젝트 역추적
- 예약 스캔 + 용량 임계치 알림, 메뉴 막대 표시
- 중복 파일 찾기, Docker/VM 이미지 카테고리, CLI

---

## 11. 작업 분해 (WBS)

`[P]` = 같은 마일스톤 안에서 병렬 가능(파일 겹침 없음 → `impl-worker` 병렬). 공통 파일(`Support/`, `Package.swift`, 모델 타입)은 M0에서 먼저 확정.

### M0 — 골격
- **M0-T1** `Package.swift`, 빈 SwiftUI 창, `STATUS.md` 생성, `Support/` 프로토콜과 공통 모델 타입(`Node`, `Attribution`, `CatalogEntry`, `CleanupPlan` 선언만), `setiopolicy_np` 호출.
- **M0-T2** `build-app.sh`(§2 서명, §2.2 Info.plist). NowPlayingBar `build-app.sh` 구조 참고.
- **M0-T3** FDA 검사 + 온보딩 화면(§3-1).
- 완료 기준: 앱 실행. **사용자에게** FDA 허용 요청 → 재빌드 후에도 "허용" 유지 확인(사용자 확인 필요, 결과 `STATUS.md` 기록). 유지 실패 시 Opus 확인.

### M1 — 코어 로직 (병렬)
- **M1-T1 [P]** `Scan/` (§4) + 테스트
- **M1-T2 [P]** `Attribution/` + `attribution-rules.json` (§5) + 테스트. Apple 데몬 사전은 이 Mac의 `~/Library/Caches`·`Containers`에 있는 `com.apple.*` 중 크기 상위 30개만 작성
- **M1-T3 [P]** `Catalog/` + `catalog.json` (§6) + 테스트
- **M1-T4 [P]** `InUse/` (§7) + 테스트
- 완료 기준: `swift test` 통과. M1-T1 성능 측정치(시간·최대 메모리) `STATUS.md` 기록. 이 Mac `~/Library` 귀속 결과 분포(정확/추정/알 수 없음/고아 추정 개수) `STATUS.md` 기록.

### M2 — 읽기 전용 UI
- **M2-T1** 개요 + 탐색(선버스트, 목록, 귀속 배지) + 상세 패널
- **M2-T2 [P]** 이력 저장·증감 (§9)
- 완료 기준: 실제 스캔 결과 표시. `~/.cache/huggingface`가 "Hugging Face 라이브러리", `com.anthropic.claudefordesktop.ShipIt`이 "Claude", `com.apple.*`이 "macOS 시스템", `Adobe Camera Raw 2`가 Adobe로 표시.

### M3 — 정리
- **M3-T1** `Cleanup/` plan/execute, 안전 규칙, 재검증, 저널, 되돌리기, CLI 경로 탐색 (§8) + 테스트
- **M3-T2** 정리 시트·정리 기록 UI
- 완료 기준: §12 정리 테스트 전부 통과. 실제 확인은 테스트용으로 만든 `~/Library/Caches/com.kimmingyu.StorageLens.test` 폴더로만 수행(다른 실제 데이터로 정리 실행 금지).

---

## 12. 테스트·검증

- **픽스처 트리**(임시 디렉터리 생성): 일반 파일, 하드링크 쌍, `cp -c` clone, sparse 파일(`truncate -s 1G`), 심볼릭 링크(디렉터리 루프 포함), 권한 없는 폴더(chmod 000, 테스트 후 복구).
  - 기대: 하드링크 1회, sparse는 할당 크기, 링크 미추적, 루프 무한 재귀 없음, 권한 없는 폴더 `skipped`
- **귀속**: 가짜 `AppIndex` 주입 → §5.2 규칙 1~8 각 1개 이상, 우선순위 충돌 케이스(규칙 1 vs 3), `com.apple.*` 고아 아님, 30일 미만·사용 중 폴더 고아 아님, 이름 매칭 오탐 방지(길이 4 미만 제조사 토큰 불일치)
- **카탈로그**: 겹치는 패턴에서 가장 긴 패턴 승리, 고아가 `never` 이김, `minAgeDays` 필터
- **정리 안전**: 거부 목록 각 경로·그 상위 폴더 거부, 심볼릭 링크 경유 홈 밖 경로 거부, plan 없이 execute 불가(컴파일 수준), 만료 plan 거부, plan 후 경로 교체(inode 변경) 시 건너뜀. 실제 trash는 임시 디렉터리에서만.
- 모든 테스트는 홈 디렉터리를 주입받음(실제 `~` 사용 금지).
- **성능**: 실제 Data 볼륨 스캔 시간·최대 메모리(긴 출력 → `sim-runner`)

## 13. Sonnet 규칙
- 작업 단위 끝날 때마다 `STATUS.md` 갱신
- 카탈로그 항목·안전 규칙·거부 목록·귀속 규칙 순서 변경 = Opus 확인 필요
- 성능 목표 미달, FDA 유지 실패, 실측 구조가 §1.4와 다름 → 구현 멈추고 "Opus 확인 필요"
- 실제 사용자 데이터에 대한 정리 실행 금지(§11 M3 완료 기준의 테스트 폴더만)

## 14. 결정 사항 기록

| 날짜 | 결정 | 주체 |
|---|---|---|
| 2026-10-28 | 프로그램 귀속 표시 v1 포함 | 사용자 |
| 2026-10-28 | root 영역 정리 v2 | Opus 제안, 사용자 동의 |
| 2026-10-28 | HF 모델 삭제 v2 (공유 blob 구조 실측) | Opus |
| 2026-10-28 | TM 스냅샷 삭제 v2 (root 필요, 현재 스냅샷 0개) | Opus |
| 2026-10-28 | Homebrew·pip은 명령 대신 캐시 폴더 trash (`brew cleanup`은 캐시 외 구버전 패키지까지 제거) | Opus |
| 2026-10-28 | M1을 M0 FDA 유지 확인과 병렬 착수 (코어 로직은 FDA 무관, 확인 실패 시 build-app.sh만 영향) | Opus |
| 2026-10-28 | 고아 추정 조건 강화: 같은 제조사 접두 설치 앱 있으면 제외, 이름에 설치 앱 번들 ID 포함 시 제외 (실측 오탐 MATLAB·Polaris·Vivid) | Opus |
| 2026-10-28 | 카테고리 합계: 매칭 노드 하위에 더 구체적 패턴 있으면 계속 하향, 이중 집계 제거 (homebrew 0 표시 문제) | Opus |
| 2026-10-28 | Cleaner는 카탈로그 매칭을 호출자에게 받지 않고 직접 계산 (안전 판정의 호출자 의존 제거) | Opus |
| 2026-10-28 | 마지막 컴포넌트 심볼릭 링크도 정리 거부, 대소문자·유니코드 변형 경로 거부 (§8.1보다 엄격, 유지) | Opus |
| 2026-10-28 | JSON 리소스는 최상위 Resources/, StorageCore는 Data/URL 입력, SwiftPM resources 미사용. CLI 경로 탐색 `ToolLocator`는 Support/에 두고 M3 재사용 | Opus |
| 2026-10-29 | v1.1(§16): `never`→`discouraged`(비권장, 개별 확인 후 정리 가능). 앱 데이터·컨테이너·HF 캐시·개인 폴더 내용 정리 허용. 차단 유지: 홈·~/Library·개인 폴더 자체, Keychains·Mail·Messages·Photos·`*.photoslibrary`·.ssh·.gnupg, Mobile Documents는 evict만 | 사용자 결정 (§15.3a 안전 완화) |
| 2026-10-29 | v1.1: iCloud 전용 화면, 앱별 데이터 화면, 창 크기 자동 조절, 한국어·상태 점검 | 사용자 요청 |

---

## 15. Opus 진행 모드 운영 규칙

`~/.claude/CLAUDE.md` "Opus 진행 모드"로 진행할 때 적용. §13의 "Sonnet 규칙"은 아래 역할로 읽는다: 구현 = `impl-worker`(Sonnet), 실행·집계 = `sim-runner`(Haiku), 판단·`STATUS.md`·`FIX_GUIDE.md` = Opus 본 세션.

### 15.1 진행 단위
- 마일스톤 하나씩 진행. 각 마일스톤 완료 기준(§11) 충족 확인 후 `STATUS.md` 갱신 → 다음 마일스톤.
- M0는 순차(M0-T1 → T2 → T3). M1은 T1~T4 병렬. M2-T1과 M2-T2 병렬. M3는 순차.
- 같은 작업 위임 3회 실패 → 중단하고 사용자에게 보고.

### 15.2 빌드 격리
- 병렬 작업자는 각자 `swift build/test --scratch-path .build-<작업ID>` 사용 (예: `.build-M1-T2`). 기본 `.build`는 Opus·`sim-runner`의 통합 빌드 전용.
- 병렬 작업 종료 후 Opus가 `sim-runner`로 통합 `swift build && swift test` 1회 실행.
- `.build-*`는 `.gitignore` 대상(M0-T1에서 추가).

### 15.3 사용자 확인 지점 (서브에이전트 실행 금지, Opus가 멈추고 사용자에게 요청)
| 시점 | 내용 |
|---|---|
| M0-T2 첫 `build-app.sh` 실행 | `codesign`의 키체인 접근 팝업 → "항상 허용". 이 실행은 Opus가 사용자에게 알린 뒤 직접 수행 |
| M0 완료 | 시스템 설정에서 StorageLens FDA 허용 → 재빌드 → 허용 유지 확인 |
| M2 완료 | 실제 화면 확인(귀속 표시 4개 사례) |
| M3-T1 수동 확인 | 테스트 폴더 정리·되돌리기 동작 확인 |

### 15.3a "Opus 확인 필요" 처리
- 서브에이전트가 보고한 "Opus 확인 필요"·계획 이탈·성능 미달 등은 **Opus 본 세션이 즉시 판단**하고 진행한다(사용자 대기 없음). 결정은 §14 표와 `STATUS.md`에 한 줄 기록, 계획 변경이면 해당 절 수정.
- 예외 — Opus가 결정하지 않고 사용자에게 묻는 것: 안전을 **완화**하는 변경(§8.1 거부 목록 축소, 카탈로그 safety 상향(`review`→`safe`, `never`→그 외), 실제 사용자 데이터 정리 실행), §1.2/§1.3 범위 변경, 같은 작업 3회 실패.

### 15.4 위임 프롬프트 필수 항목
1. 작업 ID와 PLAN.md 절 번호(예: "M1-T2, §5 전체, §12 귀속")
2. 수정 허용 파일·폴더 목록 (그 밖 수정 금지)
3. 빌드 폴더 경로(§15.2)
4. 실행할 검증 명령
5. 반환 형식: 변경 파일, 테스트 통과/실패 수, 미해결 이슈, "계획 이탈 여부"

### 15.5 Opus 직접 검토 대상
요약만으로 넘기지 않고 Opus가 코드를 직접 읽는다: `Cleanup/` 전체(§8 안전 규칙), 고아 판정 로직(§5.2), `build-app.sh` 서명 부분, `setiopolicy_np` 호출 위치.


---

## 16. v1.1 개정 (2026-10-29, 사용자 피드백)

사용자 실사용 피드백: ① 창 크기·비율 자동 조절 ② iCloud 별도 확인 ③ "정리 금지" 대신 "정리 비권장", 수동으로 다 정리 ④ 앱 데이터 정리 ⑤ 전체 번역·상태 점검, 최적화·사용성 개선.
사용자 결정(2026-10-29): 정리 범위 = "개인 폴더까지 열기", iCloud = "전용 화면". 이 절이 §6.2·§8.1·§12와 충돌하면 이 절이 우선.

### 16.1 안전 등급 변경 (§6.1·§6.2 대체)
- `Safety` = `safe` | `review` | `discouraged`. `never` 제거. JSON 디코딩 시 `"never"`는 `discouraged`로 읽음(구버전 호환).
- 의미: `safe` 일괄 선택 가능. `review` 개별 선택 + 경고. `discouraged`(UI 표기 "정리 비권장") 개별 선택만, 빨간 경고 + 정리 시트에서 "비권장 항목임을 이해했습니다" 체크 후에만 실행 버튼 활성. 일괄 선택(여러 항목 한 번에)에 `discouraged`가 섞이면 `discouraged` 항목만 체크 요구(차단 아님).
- 카탈로그 변경:

| id | safety | method | note(요지) |
|---|---|---|---|
| huggingface | discouraged | trash | 공유 저장소 구조라 모델 폴더만 지우면 공간이 거의 안 빠지고 다른 모델이 깨질 수 있음. 전체 폴더 정리는 모든 모델 재다운로드 |
| app-support | discouraged | trash | 앱 설정·로그인·문서가 사라질 수 있음. 앱 종료 후 정리 |
| containers | discouraged | trash | 샌드박스 앱 데이터. 앱 종료 후 정리, 앱이 초기 상태가 됨 |
| app-preferences (신규) | discouraged | trash | `~/Library/Preferences/*` (`com.apple.*` 제외). 앱 설정 초기화 |
| saved-state (신규) | safe | trash | `~/Library/Saved Application State/*` |
| personal-files (신규) | discouraged | trash | `~/Documents/*`, `~/Desktop/*`, `~/Pictures/*`, `~/Movies/*`, `~/Music/*`. 개인 파일. 휴지통에서 복구 가능 |
- 나머지 항목 그대로. 카탈로그에 없는 경로: 개인 폴더 하위면 `discouraged`, 그 밖은 `review`(기존).
- 고아 항목 우선순위(§6.1)는 `discouraged`에도 동일 적용.

### 16.2 경로 안전 규칙 변경 (§8.1 대체 부분)
- **하드 차단 목록**(그 자체·하위 전부·상위 폴더 거부, 어떤 확인으로도 해제 불가): `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Photos`, `~/.ssh`, `~/.gnupg`, 그리고 이름이 `.photoslibrary`로 끝나는 경로 컴포넌트가 있는 모든 경로(그 자체·하위). `~/Library/Mobile Documents`는 기존대로 evict만.
- **자체만 차단**(하위 내용은 허용): `~`, `~/Library`, `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`, `~/Downloads`, `~/Library/Application Support`, `~/Library/Containers`, `~/Library/Group Containers`, `~/Library/Caches`, `~/Library/Preferences`, `~/.cache`.
- **상위 폴더 규칙 유지**: 하드 차단 경로(및 Mobile Documents)를 포함하는 상위 폴더 선택은 거부. 예: `~/Library` 전체, `~/Pictures`(photoslibrary 포함 시는 자체 차단으로 이미 거부).
- `~/.cache/huggingface`는 거부 목록에서 제거(카탈로그 `discouraged`로 처리).
- 나머지 §8.1(realpath·심볼릭 링크·trashItem만·plan/execute·재검증·만료, §14의 대소문자·유니코드 변형 거부) 전부 유지. 앱이 휴지통을 비우는 기능 금지 유지.
- `CleanupPlanItem`에 `isDiscouraged: Bool` 추가. `execute`는 계획에 `discouraged` 항목이 있으면 `acknowledgedDiscouraged: Bool` 인자가 true일 때만 그 항목 실행(아니면 해당 항목 skipped, 이유 "비권장 항목 확인 안 됨"). UI 체크와 별개로 코어에서도 강제.

### 16.3 앱별 데이터 (신규, "앱 데이터 정리")
- 코어 `AppDataIndex`(Session/): 스캔 결과에서 아래 위치의 **직속 자식** 노드를 귀속 앱 기준으로 묶는다: `~/Library/{Caches, Application Support, Containers, Group Containers, Logs, Preferences, Saved Application State, HTTPStorages, WebKit}`, `~/.cache`. 묶음 키 = 귀속 `bundleID` 있으면 그것, 없으면 `appName`. `com.apple.*`/macOS 시스템 귀속은 "macOS 시스템" 한 묶음(목록 맨 아래, 기본 접힘).
- 묶음 정보: 앱 이름·아이콘 소스·총 크기·항목 목록(경로, 위치 종류 한국어명 예 "캐시"/"앱 데이터"/"컨테이너"/"설정"/"로그", 크기, 카탈로그 safety)·실행 중 여부(InUse 또는 실행 앱 목록)·고아 추정 여부.
- UI "앱별" 화면: 크기순 앱 목록 → 선택 시 항목 목록(체크박스, 기본: `safe`만 체크) → "선택 항목 정리…" → 기존 정리 시트(§16.2 확인 체크 포함). 앱 실행 중이면 상단 경고 "앱 종료 후 정리 권장". "캐시만 선택" 빠른 버튼.

### 16.4 iCloud 전용 화면 (신규)
- 코어 `ICloudInventory`(Session/): 스캔 결과의 `~/Library/Mobile Documents` 직속 자식(컨테이너)마다 표시 이름(`com~apple~CloudDocs` → "iCloud Drive", `iCloud~a~b~c` → 번들 ID `a.b.c`로 AppIndex 조회해 앱 이름, 실패 시 마지막 토큰), 로컬 사용 크기(할당 크기 합), 클라우드 전용 파일 수(dataless), 전체 파일 수.
- 업로드 대기 수: 컨테이너 선택 시 지연 조회(`URLResourceValues.ubiquitousItemIsUploaded` 등, dataless 파일은 건너뜀, 파일 2만 개 상한 후 "일부만 확인" 표시). 메인 스레드 금지, 취소 가능. 파일 내용 읽기·다운로드 유발 금지(setiopolicy 유지).
- UI "iCloud" 화면: 상단 요약(iCloud 로컬 사용량 총합, 클라우드 전용 개수), 컨테이너 목록 → 선택 시 하위 폴더 목록 + "로컬 사본 내리기…"(기존 icloudEvict 정리 시트). 
- 개요 화면: 카테고리 합계와 별도로 "iCloud 로컬 사본" 한 줄 + iCloud 화면 이동 버튼. 다른 카테고리 합계에 iCloud 크기를 섞지 않음.

### 16.5 창 크기·비율 자동 조절
- 첫 실행 기본 창 크기 = 현재 화면 `visibleFrame`의 75%×80%(최소 900×600, 최대 1600×1100), 이후 macOS 창 복원에 맡김. 최소 크기 760×520.
- 탐색 화면: 폭 ≥ 1100이면 선버스트|목록|상세 3열, 760~1100이면 상세 패널을 목록 아래 또는 접이식(토글 버튼), 선버스트는 항상 1:1 비율 유지(`aspectRatio(1, .fit)`), 남는 공간 가운데 정렬. 목록 열 폭은 창 폭에 비례.
- 정리 시트·기타 시트: 고정 최소폭 대신 부모 창 크기 비례(폭 60%, 최소 520·최대 900), 내용 스크롤.
- 글자 크기 고정값 금지(시스템 동적 크기 사용).

### 16.6 한국어·상태 점검·사용성
- 사용자에게 보이는 모든 문자열 한국어: UI, StorageCore가 돌려주는 거부·실패 이유, 귀속 근거, 카탈로그 title/note(예 "Application Support" → "앱 데이터 (Application Support)"), 열거형 원시값 노출 금지. Info.plist `CFBundleDevelopmentRegion`=`ko`, `CFBundleLocalizations`=[`ko`] (시스템 오류 메시지 한국어화). 날짜·숫자 `ko_KR`.
- 상태 표시: 스캔 진행(처리 항목 수·현재 경로·경과 시간·취소), 빈 상태·오류 상태 문구, `HistoryStore`·저널 저장 실패를 `try?`로 삼키지 말고 화면 하단 비차단 배너로 표시.
- 성능: 큰 목록은 Lazy 컨테이너, 정렬·합계·묶음 계산은 메인 액터 밖에서 1회 계산 후 캐시. 스캔 중 UI 멈춤 없음.
- 사이드바: 개요 · 탐색 · 앱별 · iCloud · 정리 기록. 마지막 선택 화면 기억(UserDefaults).

### 16.7 작업 분해
- **V11-T1 [P] 코어 안전**: `Catalog/CatalogEntry.swift`, `Catalog/Catalog.swift`, `Cleanup/*`, `Session/CleanupSupport.swift`, `Resources/catalog.json`, `Tests/CatalogTests.swift`, `Tests/CleanupTests.swift`. §16.1·§16.2. 테스트: 하드 차단 각 경로·하위·상위 거부, `.photoslibrary` 어디서든 거부, 자체만 차단 목록의 자체 거부·하위 허용, discouraged 미확인 시 skipped, 확인 시 실행, `"never"` JSON 호환, 개인 폴더 미분류 경로 discouraged.
- **V11-T2 [P] 코어 앱별·iCloud**: 신규 `Session/AppDataIndex.swift`, `Session/ICloudInventory.swift`, 필요 시 `Session/ScanOutcome.swift`·`Session/StorageSession.swift` 공개 API 추가만, 신규 `Tests/AppDataTests.swift`. §16.3·§16.4 코어.
- **V11-T3 UI**(T1·T2 후): `Sources/StorageLensApp/*`, `Resources/Info.plist`, StorageCore 내 사용자 노출 문자열 번역(로직 변경 금지). §16.1 UI·§16.3~§16.6.
- 완료 기준: `swift test` 전부 통과, `build-app.sh` 서명 빌드 성공, 사용자 확인(§16.8).

### 16.8 사용자 확인 (v1.1)
- 창 크기 조절·화면 비율, 앱별 화면, iCloud 화면, 한국어 표시.
- 테스트 폴더(`~/Library/Caches/com.kimmingyu.StorageLens.test`) 정리 → 휴지통 → 되돌리기 (§15.3 M3 항목 그대로).
- 실제 사용자 데이터 정리는 사용자가 앱에서 직접 수행. Opus·서브에이전트는 테스트 폴더 외 정리 실행 금지 유지.

## 17. v1.2 개정 (2026-10-29, 다분야 감사)

항목 상세(원인·영향·방향·파일): `AUDIT_v1.2.md`. 아래는 배정·판단·검증. 이 절이 §3~§16과 충돌하면 이 절 우선. 상세 원본 계획: ~/.claude/plans/1-storage-lens-tranquil-bee.md

### 17. 운영 방식 (Opus 진행 모드, PLAN §15 준용)
- Opus 본 세션: 계획 문서화, 작업 분배, 결과 검토, 판단. 코드 직접 수정 금지.
- 구현 = `impl-worker`(Sonnet), 빌드·테스트·성능 측정·삭제 실행 = `sim-runner`(Haiku).
- 승인 직후 Opus 첫 작업: 이 계획을 `PLAN.md §17 v1.2`로, 항목별 수정 방향을 `FIX_GUIDE.md F7~`로 기록, `STATUS.md`에 v1.2 시작 기록.
- 병렬 impl-worker는 수정 파일 겹침 금지(아래 소유 파일 표). 빌드는 워커별 `--scratch-path <scratchpad>/build-<task>` (프로젝트 루트에 `.build-*` 새로 만들지 않음).
- 각 단계 끝: sim-runner `swift test` 전체 + 서명 빌드(`build-app.sh`) → Opus가 Cleanup/PathSafety/Attributor diff 직접 검토(§15.5) → 사용자 GUI 확인 요청.
- 워커가 계획 밖 설계 문제 발견 시 코드 변경 말고 반환 → Opus 판단 후 재지시.

### 17. 단계 0 — 정리 (sim-runner)
- 루트 `.build-M1-T1 … .build-perf` 9개만 존재 확인 후 삭제. `.build/`, `build/` 유지. `.gitignore`에 `.build-*/` 추가(Opus 문서 수준 변경).

### 17. 단계 A — 안전·정확성 (A1~A3 병렬 → A4)

**판단 확정(Opus)**
- 정리 경로 검사는 전부 fail-closed. 읽기 실패 = 안전 확인 불가 → 거부(ENOENT만 예외).
- 실행 직전 재검증의 하위 전체 순회는 유지(안전 우선). 비용은 순회 통합·취소·진행 표시로 해결.
- 제조사 토큰이 설치 앱 2개 이상에 해당하면 특정 앱 귀속 금지 → `vendor:<token>` 공용 그룹("Google 공용" 등). 1개일 때만 앱 귀속.
- 디렉터리당 상위 200 파일 한계: AppDataIndex 위치(Preferences 등 앱별 화면 대상 디렉터리)만 직속 파일 전부 유지. 그 밖은 기존 유지하되 omittedBytes를 그룹·카테고리 합계에 반영, "일부 파일 생략" 표기.
- 하드링크 집계 결정성: 스캔 후 nlink>1 inode만 정렬 경로 최솟값 폴더에 배정. 스캔 시간 +5% 초과 시 Opus 재판단.

| 작업 | 소유 파일 | 항목 |
|---|---|---|
| A1 Cleanup 코어 | Cleanup/PathSafety.swift, Cleaner.swift, Journal.swift, CleanupPlan.swift, CleanupTests.swift | safety-3(.photoslibrary 순회 fail-closed), safety-4(trash 기록에 dev/inode/size, undo 전 일치 확인, .Trash/.Trashes 접두 검증·링크 거부, 구기록은 undo 비활성), safety-5·cq-9(Journal 프로세스 단일 인스턴스+flock, 개행 보정 후 단일 write, 손상 줄 수 반환), safety-6(icloudEvict 파일별 업로드 완료 확인·미업로드 skip, 실패 목록 100건+요약, 순회 취소), safety-8·perf-5(photoslibrary 탐지+크기 측정 1회 순회, FileEntry 크기 재사용, Task 취소 확인, 진행 콜백), safety-13(측정 실패 건수 집계·identity 실패 거부), safety-2 Cleaner 측(카탈로그 비었으면 plan 전부 거부·execute 전부 skip, homeMismatch 방식), safety-7 코어 측(execute 루프 취소 시 남은 항목 skipped 기록) |
| A2 Session·Support | Support/ToolLocator.swift, Session/StorageSession.swift, History/HistoryStore.swift, Support/ProcessLister.swift, build-app.sh, Package.swift, 새 테스트 파일 ToolLocatorTests.swift·HistoryCorruptionTests.swift | safety-1(xcrun 등 시스템 도구는 /usr/bin 고정, 그 외 후보는 소유자 root/본인·그룹/타인 쓰기 불가만 허용, 비표준 경로 플래그 노출), safety-2·cq-2(카탈로그·규칙 로드 결과를 오류 사유 포함 타입으로, 항목 단위 디코딩 격리), safety-15(postProcess 단계 사이 취소 확인, 취소 시 결과 미적용), cq-8(손상 이력 격리·보존 한도 포함·schemaVersion), cq-11·cq-2(build-app.sh에 서명 ID 유효성·필수 리소스·JSON 구문 사전 검사), ProcessLister:54 deprecated 경고 |
| A3 귀속·스캔 | Attribution/Attributor.swift, Session/AppDataIndex.swift, Scan/Scanner.swift, Session/CategoryTotals.swift, AttributionTests·AppDataTests·ScanTests | safety-9(제조사 공용 그룹), perf-2(규칙 7 정규화 이름 사전 init 1회, 정규식 제거·정적화), perf-13(상속 근거는 원 규칙+깊이, 캐시 상한), safety-12(위 결정), safety-11·perf-15(하드링크 결정성), perf-8(상위 200 부분 선택 후 Node 생성), design-14 코어 측(위치 종류를 문자열 대신 enum 식별자로 노출) |
| A4 UI 안전 (A1~A3 후) | AppModel.swift, MainView.swift, CleanupSheet.swift, 새 Session/CleanupFlowMachine.swift + 테스트 | usability-2·safety-7(실행 중 interactiveDismissDisabled, planning 단계 취소, 닫힘 경로 closeCleanup 통일, isExecuting으로 중복 시작 차단, 실행 Task 보관·종료 시 경고), cq-1(정리 흐름 단계 전이를 순수 상태 머신으로 StorageCore에 추출·테스트), A1·A2 새 오류 노출(카탈로그 로드 실패 배너, 저널 손상 N건 배너, iCloud 업로드 대기 수 시트 경고, 측정 제외 N건, 비표준 도구 경로 경고) |

### 17. 단계 B — 사용성·키보드·접근성 (B1 → B2·B3 병렬)

**판단 확정(Opus)**: 부분(하위 경로) 재스캔은 v2(§10). 이번엔 재스캔 후 이전 focusPath 복원(없으면 가장 가까운 상위). 한국어 단일 UI 유지(§16.6).

B1이 AppModel 공개 API를 먼저 추가하고 B2·B3는 그것만 사용: `navigate(to: Section)`, `reveal(path:)`(탐색 화면으로 이동+포커스), `goUp()`, `rescan()`, `startCleanupForSelection()`, `recheckFullDiskAccess()`, `announce(_:)`(VoiceOver 공지).

| 작업 | 소유 파일 | 항목 |
|---|---|---|
| B1 명령·흐름 | StorageLensApp.swift, AppModel.swift, MainView.swift, RootView.swift | usability-1·design-4·a11y-11(Commands: ⌘R 스캔/재스캔, ⌘. 취소, ⌘1~5 화면, ⌘↑ 상위, ⌘F 검색 포커스, ⌘⌫ 정리; 툴바에 스캔·정리), usability-6·design-13 후반(부분 모드 지속 배너: 시스템 설정 열기·다시 확인, 앱 활성화 시 FDA 재확인, 미사용 MainPlaceholderView 제거), usability-5(focusPath 복원), usability-12(실패 스트립 다시 시도·닫기, 중복 표시 제거), usability-15(지난 스캔 소요 시간 참고 표시, 부분 범위 배지 전 화면), a11y-9(완료·실패·정리 결과 공지, 고빈도 텍스트 접근성 제외), perf-3(진행 갱신 150ms 합치기, 진행값·상태 분리 관찰), perf-10(선택 가용성 Task 보관·취소) |
| B2 탐색 | ExploreView.swift, DetailPanel.swift, SunburstView.swift | usability-3(선택 N개·합계 상시 표시, 다중 선택 시 요약 카드), usability-4(현재 폴더 이름 검색, 이름순 정렬, 사용 중·비권장·고아 칩 필터, 생략 행 설명+Finder 열기), usability-13·design-9(경로바 중간 생략, 우측 컨트롤 고정), 행 컨텍스트 메뉴(Finder에서 보기·경로 복사·정리…), Return 진입, a11y-5(행 결합 요약 라벨+폴더 열기 액션), a11y-4(아이콘 버튼 라벨·장식 이미지 숨김), usability-9·design-1·a11y-1(선버스트 호버 툴팁·목록 행 상호 하이라이트, 큰 조각 이름 표기, 상위 N 조각 접근성 요소+액션), design-12(최상위 중앙 버튼 → 현재 폴더 이름·크기), design-2(좁은 폭 패널 레이아웃 포함, 기본 숨김), design-3(열 기준을 콘텐츠 폭으로 통일, PLAN §16.5 문구 갱신은 Opus), design-8(행 비율 막대) |
| B3 기타 화면 | OverviewView.swift, AppsView.swift, JournalView.swift, ICloudView.swift, CleanupSheet.swift | usability-7(증감·카테고리 행 클릭 → reveal), usability-14·design-14(정렬 가능 열, 머리글 전체 선택, 비활성 사유 푸터, 재스캔 후 동일 경로 체크 유지, 캐시만 선택은 enum 사용), a11y-2(체크박스 라벨=항목 이름+안전도), usability-11(되돌릴 수 없는 이유 한 줄, 날짜별 그룹·결과 필터·검색, undo 결과 행 피드백), usability-8(조회 중 내리기 비활성·안내, 경고 범위 문구), usability-10·design-5(실행 버튼 "휴지통으로 이동 (N개, 크기)" 등 방법별 문구, 상단 고정 요약, 거부 항목 접기, 결과 단계 "닫고 재스캔"), perf-9(AppsView 동일 입력 재계산 생략), perf-11(시트 LazyVStack+경로 id), perf-14(개요 정렬·가용성은 스캔 완료 시 1회 계산 — 계산 위치는 AppModel에 B1이 프로퍼티 추가) |

### 17. 단계 C — 디자인 다듬기·성능 (C1·C2·C3 병렬)

| 작업 | 소유 파일 | 항목 |
|---|---|---|
| C1 디자인 체계 | 새 Theme.swift·Components.swift(Badge·Banner·SafetyTag), 모든 *View.swift 표시부(B 완료 후라 단독 소유), Format.swift | design-10(공용 배지·배너·색 토큰, 시맨틱 색), design-6(용어집 적용: 귀속→소속 앱 등, 개발자 문구·v2 제거, 숫자는 Fmt.count), design-7(개요 위계: 용량 요약 최상단, 카테고리 비율 막대), design-11(선버스트 colorScheme별 밝기·외곽선), a11y-3(증감 화살표, 안전도 아이콘, VolumeBar 요약 라벨), perf-12(조각 색 1회 계산, fill+stroke 합치기) |
| C2 성능 코어 | Session/SunburstLayout.swift, Session/ScanOutcome.swift, InUse/InUseIndex.swift, IconProvider.swift, AppModel.swift(arcs 계산 경로만) | perf-1(arcs를 rows와 같은 취소 가능 detached 작업으로, 임계 미만 사전 제거), perf-4(InUse 링크 해석 생략 가능 검토·(경로,정렬) LRU·이전 focus 작업 취소), perf-6(아이콘 음성 캐시·백그라운드 로딩·표시 크기 축소·상한) |
| C3 빌드·아이콘·테스트 정리 | build-app.sh, Resources/Info.plist, 새 scripts/make-icon.swift, Resources/AppIcon.icns, 새 Tests/StorageCoreTests/TestSupport.swift + 기존 테스트의 헬퍼 호출부 | 선버스트 모티프 아이콘을 스크립트로 그려 iconset→icns(iconutil), Info.plist CFBundleIconFile, 버전 문자열 한 곳 주입(cq-11), cq-12(리소스 로더·FixedClock·임시 홈 헬퍼 공용화) |

### 17. 기각(수정 안 함, PLAN §17에 이유 기록)
design-15, perf-7, safety-10, safety-14, a11y-6·7·8·10·12, cq-3·4·5·6·7·13·14 — 결정 사항이거나 근거 부족.

### 17. 검증
- 각 작업: 워커가 자기 scratch 경로로 `swift build` + 관련 테스트 통과, 항목별 신규 테스트(특히 A1: 읽기 불가 하위 폴더 속 .photoslibrary 거부, 휴지통 동명 다른 파일 undo 거부, 잘린 저널 줄 뒤 append 정상, 미업로드 iCloud 파일 skip, 빈 카탈로그 전부 거부; A2: 사용자 쓰기 디렉터리의 가짜 xcrun 무시, 손상 이력 격리; A3: 제조사 2앱 → 공용 그룹, Preferences 201+ plist 합계 정확, 하드링크 반복 스캔 결정성).
- 단계 끝: sim-runner `swift test` 전체 통과(현재 111 + 신규), release 성능 측정(Data 볼륨 전체: 기준 12.3s·0.53GB → 13.5s·0.6GB 이내), `SL_ATTR_REPORT=1` 귀속 분포 비교, `build-app.sh` 서명 빌드 + `codesign --verify --strict`.
- Opus 직접 검토: A1 전체 diff, A3 Attributor diff.
- 사용자 GUI 확인(Opus가 멈추고 요청): A 후(정리 시트 Esc 차단·계획 취소·배너), B 후(단축키·검색·컨텍스트 메뉴·VoiceOver 선버스트·FDA 배너), C 후(아이콘·다크 모드·개요). FDA 유지 확인(서명 ID 동일).
- 완료 시 STATUS.md 압축 기록, 메모리 storage-lens-project 갱신.

### 17.x 사용자 지시 추가 (2026-10-29): Liquid Glass 표준
- 디자인은 Liquid Glass 표준 적용. 규칙·화면별 매핑은 `GUIDELINES.md`(Opus 작성)가 기준. 배포 대상 macOS 26.0이라 분기 없음.
- B2·B3: 자기 화면 작업 시 GUIDELINES.md를 함께 적용(커스텀 배경 제거, 시스템 컨트롤, 떠 있는 컨트롤만 유리). B2 상세 패널은 `.inspector`로 전환(design-2 대체), 탐색 검색은 `.searchable`.
- C1 재정의: Theme.swift 토큰 + B1 소유였던 MainView·RootView·StorageLensApp의 유리 적용(배너·진행 띠 → 떠 있는 유리 카드, 툴바 그룹·ToolbarSpacer, navigationSubtitle) + 전 화면 GUIDELINES §4 금지 목록 감사.
- B1 결정 승인: 사이드바 열거는 기존 `SidebarItem` 사용, 단일 `Window`(다중 창 불필요), 지난 스캔 소요 시간은 앱 UserDefaults 저장(이력 스키마 변경 안 함).
- §16.5 개정(v1.2): 3열/2열 창 폭 기준 폐지 → 상세 패널은 `.inspector`, 탐색 본문은 콘텐츠 폭 600 기준 선버스트 상/좌 배치(GUIDELINES §5).
- §8.2 저널 정책(v1.2): journal.jsonl 2MB 초과 시 journal.1.jsonl로 회전(1세대만 보관), 화면·되돌리기는 두 파일 합본 기준.
