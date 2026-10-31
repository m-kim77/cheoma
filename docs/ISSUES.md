# 고칠 문제

2026-10-30 밤 점검 결과를 정리한 목록이다 (서브에이전트 16개: 코드 리뷰, 빌드 경고, 실행 중인 앱 측정, 로그·크래시 확인).
줄 번호는 그날 기준이다 (main `055ba92`, agents `2b0d285`). 고치면 이 문서에서 지우고 [PROGRESS.md](PROGRESS.md) 작업 기록에 남긴다.

전체 상태: 크래시 0건, 메모리 누수 없음. 대시보드를 닫았을 때 CPU 0.3~0.8%, 도우미 0%. debug·release 빌드 warning 0건.
그래서 전부 고칠 필요는 없다. **"꼭 고칠 것"만 배포 전에 고치고**, 나머지는 시간 날 때 하거나 그냥 둬도 된다.

## 꼭 고칠 것

팬 안전·보안, 기록이 망가지는 버그, 큰 성능 회귀.

1. **팬 복원 실패를 무시함** — `Sources/CheomaFanHelper/main.swift:91-96`
   `restoreAutomatic`이 SMC 쓰기 결과를 버리고 `isManual = false`로 바꾼다. 쓰기가 실패하면 팬이 멈춤(0 RPM) 상태로 남는데, watchdog은 다시 시도하지 않는다.
   → 하나라도 실패하면 `isManual`을 유지하고 watchdog 주기마다 다시 시도한다.

2. **도우미가 혼자 자동으로 되돌려도 앱은 모름** — `Sources/Cheoma/Fans/FanController.swift:265`, `main.swift:108`
   keepAlive 20초 초과(벽시계 `Date()`로 재서 잠자기 뒤에도 터짐)나 95°C 한계로 도우미가 되돌려도, 앱 UI는 고정·멈춤으로 보이고 다시 적용하지 않는다. 10/30 도우미 로그에 "자동으로 되돌림: CPU 95°C"가 실제로 있다.
   → 도우미는 단조 시계(`DispatchTime`/`systemUptime`)로 재고, `keepAlive` reply로 `isManual`을 돌려준다. 앱은 false면 `appliedRPMs = nil` 후 `reconcile()`, 깨어날 때(`didWakeNotification`)도 같은 처리.

3. **root 도우미 접근 제어가 약함**
   - 클라이언트 확인이 실행 파일 경로 비교뿐이다 — `main.swift:141`. 같은 사용자의 아무 프로세스가 팬을 멈출 수 있다.
     → `connection.setCodeSigningRequirement(...)` (ad-hoc 서명이면 설치할 때 identifier + cdhash 고정).
   - 설치 스크립트와 바이너리를 `$TMPDIR`에 만들어 두고 암호 창이 떠 있는 동안 둔다 — `FanController.swift:409-441`. 그 사이 바꿔치면 root로 실행된다.
     → root 셸 안에서 원본을 복사하고 서명을 확인한 뒤 설치. 길게 보면 `SMAppService.daemon`.

4. **디스크·네트워크 속도가 1.8e19 B/s로 튐** — `Stats/Samplers/DiskSampler.swift:29-30`, `NetworkSampler.swift:29-30`
   외장 디스크·DMG를 빼거나 USB 이더넷·테더링을 끊으면 합계 카운터가 줄어 `&-`가 래핑된다. 이 값이 기록 파일에 저장돼 재시작 뒤에도 그래프 스케일이 망가진다.
   → 줄어들면 이번 값은 nil, 기준값만 갱신 (또는 장치·인터페이스별 델타).

5. **그래프 탭을 열면 CPU 약 110%** (1분 구간, 초당 23번 그림)
   설치된 v0.1.0에서도 같다. 10/29 NOTES.md에는 1%였다. 초당 23번은 설계대로이고(`TimeGraph.swift:65-68`), 한 번 그릴 때 약 48ms를 쓰는 게 문제다. 그래프 하나가 아니라 주변까지 매번 다시 계산하는 것으로 보인다.
   의심: `.periodic(from: .now, …)`가 body마다 새로 만들어짐 / 광화문 배경 Canvas가 그릴 때마다 점 수천 개 재계산(`Gwanghwamun.swift:163-164`) / 대시보드 전체 배치 재계산.
   → `b7be670` → `f76ce7d`(광화문 테마) → `f0503f9` 순서로 `--bench` 비교, `sample`로 확인. (`--bench`는 300초 넘기면 본 앱 기록 파일을 덮어쓰니 짧게 돌린다. 아래 "나중에" 참고.)

6. **숨긴 메뉴바 아이콘이 최대 10분간 펼쳐진 채 남음** — `MenuBar/StatusBarController.swift:192-196`
   `hasPopup`이 그 앱의 layer>0 창을 전부 메뉴로 본다. 메뉴바 아이콘 창 자체가 layer 25라서 메뉴를 닫아도 열린 것으로 보고, 600초 타임아웃까지 0.3초마다 메인 스레드에서 창 목록을 읽는다.
   → 누르기 직전에 그 pid의 창 ID를 저장해 두고, 그 뒤 새로 생긴 창만 메뉴로 본다.

## 고치면 좋은 것

동작이 틀리거나 체감되는 문제. 급하지는 않다.

- **샘플링이 전부 메인 스레드** — `Stats/StatsStore.swift:104-131`. IOReport 약 4ms + 온도 35개 4~6ms + 앱 목록 약 3ms. 120Hz 프레임 예산(8.3ms)을 넘길 수 있다. → 전용 serial queue에서 재고 결과만 main에 넘긴다.
- **기록 전체를 tick마다 복사** — `StatsStore.swift:131`, `StatsHistory.swift:47, 94`. `@Published history`의 append가 CoW로 시계열 전체를 복사하고(tick당 약 0.8MB), `removeFirst`가 시리즈마다 점 3600개를 당긴다. → class ring buffer + `objectWillChange` 한 번.
- **"최대" 숫자가 그래프와 다름** — `StatsHistory.swift:77`. peak가 아니라 1분 평균의 최대를 쓴다. → maximum은 `\.peak`로.
- **경고 알림이 정보성 알림에 덮임** — `Notch/NotchModel.swift:105-111`. 알림 칸이 하나라 배터리 20%·과열 경고가 잠금 해제 같은 알림에 밀리고, 쿨다운은 이미 시작돼 다시 안 뜬다. → 알림에 우선순위.
- **도우미 재시작을 실패로 처리** — `FanController.swift:283, 299-301, 357-369`. XPC interruption이면 모드를 영구히 자동으로 저장한다. 옛 연결은 invalidate하지 않는다. → interruption(4097)은 다음 tick에 재시도, 연결은 `===`로 확인 후 정리.
- **팬 슬라이더 끄는 중 노치가 닫히면 저장 안 됨** — `Notch/Dashboard/FanTab.swift:243-249`. → 드래그 중 `keepsOpen = true`, 또는 `onDisappear`에서 커밋.
- **메뉴바 정리 모드**
  - 정리 모드에서 타일을 누르면 화면 밖으로 밀린 아이콘을 누른다 — `HiddenItemsPanelController.swift:33-36`.
  - 저장된 `isHiding`을 실행 때 순서 확인 없이 적용해, 토글 ⌄가 화면 밖으로 밀리면 앱 안에서 되돌릴 수 없다 — `StatusBarController.swift:16, 56, 116-129`.
  - "완료" 때 AX 스캔을 메인 스레드에서 동기로 돌린다 — `StatusBarController.swift:140-142`.
- **전역 `mouseMoved` 모니터 상시** — `Notch/NotchWindowController.swift:39-46`, `NotchModel.swift:88-96`. 이벤트마다 작업을 다시 예약해서, 마우스를 천천히 계속 움직이면 노치가 안 열린다. → `NSTrackingArea`, 또는 들어갈 때 한 번만 예약.
- **대시보드 렌더링 비용** — `DashboardView.swift:452-459`(그래프 탭 `summary()`가 그릴 때마다 약 5천 점 배열 4번), `:30`(StatsStore 전체 관찰).
- **노치 없는 화면** — 대체 화면이 `NSScreen.main`(`NotchWindowController.swift:81`, `NSScreen.screens.first`가 맞음), 전체화면 영상 위에도 검은 알약이 보임(`:91`).
- **충전기 반영이 최대 10초 늦음** — `PowerSampler.swift:42-51`. 10초 배터리 캐시를 무효화하지 않는다.
- **잠자기 뒤 첫 샘플이 0으로 기록, 벽시계 기준** — Network/Disk/IOReportEnergy, `StatsHistory.swift:47-58`. → dt가 10초 넘으면 nil, 단조 시계.

## 나중에 (선택)

- 표시 반올림 경계: "1000KB/s", "1024MB", "1000GB", "10.00W" — `Notch/Dashboard/Format.swift`.
- `--bench`가 릴리스에서도 동작하고, 300초 넘기면 본 앱 기록 파일을 덮어씀 — `CheomaApp.swift:35-40`.
- DMG I/O 이중 집계(`DiskSampler.swift:40-44`), exec 뒤 프로세스 이름 안 바뀜(`AppUsageSampler.swift:82`), argv 버퍼 1MiB 상주(`:40`).
- 자잘한 주기 작업: 충전 중 어댑터 정보 매 tick IPC(`PowerSampler.swift:62-64`), IOKit 매칭 매 tick(`SystemHelpers.swift:29-43`), `NSScreen.screens` 매 tick(`StatsStore.swift:126`), 도우미 watchdog이 자동 모드에서도 2초마다·leeway 없음(`main.swift:98-103`), 디스크 용량 조회 메인 스레드(`DiskSampler.swift:18-21`).
- 대시보드를 열면 그래픽 메모리 약 190MB (닫으면 회수됨, 누수 아님). 30Hz Canvas + 큰 shadow 의심.
- 히스테리시스 기준이 다른 모드 값으로 오염(`FanController.swift:251-252`), 8초 확인이 계속 미뤄짐(`:279, 315-320`), 종료 때 타임아웃 없는 동기 XPC(`:310-311`), osascript stderr를 끝난 뒤에야 읽음(`:567`).
- 시작할 때 이미 과열 상태면 경고가 안 뜸 — `Events/SystemEventMonitor.swift:43-59`.
- strict-concurrency warning 11건 (Swift 6 모드면 7건이 error). `swift-tools-version 5.9`라 평소엔 안 보인다.
- 확인 못 한 의심: `MemorySampler.swift:31`의 UInt32 뺄셈(purgeable > internal이면 크래시. 크래시 0건이라 실제로는 안 일어난 듯).

## 이미 고친 것 (`feature-toggles` `03d8743`, 아직 main에 안 합침)

- 노치를 열 때 직전 측정이 0.5초 안이면 즉시 측정 생략 (dt 수 ms 스파이크).
- 헤더 시계 `.everyMinute`.
- 1초 고정 타이머 제거: 열림 1초, 기록 2초, 팬 온도만 4초, 그 밖엔 멈춤 (닫혀 있을 때 헛 wakeup, 화면 꺼져도 계속 재던 문제).
- 기록이 바뀌었을 때만 저장.

## 코드 밖 (이 맥 환경)

- Macs Fan Control의 SMC 도우미(`com.crystalidea.macsfancontrol.smcwrite`)가 같이 돌고 있다. 같은 팬 키를 서로 덮어쓸 수 있으니 둘 중 하나만 쓴다.
- 옛 `com.notchbar.fanhelper`가 launchd에 아직 등록돼 있다 (`/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`). `sudo launchctl bootout system/com.notchbar.fanhelper` 후 파일 삭제.
- 저장소에 `dist/NotchBar.app`이 남아 있다.
