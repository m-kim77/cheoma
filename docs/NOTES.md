# 기술 메모

만들면서 알아낸 것과 그렇게 정한 이유. 이 맥(MacBook Pro M5 Max, macOS 26.6) 기준이다.

## 노치

- 노치 높이는 `NSScreen.safeAreaInsets.top`, 양옆 남는 영역은 `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`로 구한다. 이 맥은 화면 폭 2056pt 중 x 918~1138이 노치다.
- 노치 창은 테두리 없는 non-activating `NSPanel`이고, 메뉴바보다 위(`mainMenuWindow + 3`)에 둔다. 닫혀 있을 때는 마우스를 통과시키고(`ignoresMouseEvents`), 전역 마우스 감시로 노치 위에 마우스가 올라왔는지 본다.
- 첫 클릭이 바로 먹히도록 `acceptsFirstMouse`를 켠 호스팅 뷰를 쓴다.
- 열기 지연(0.18초)은 마우스가 들어온 순간 한 번만 잡는다. 움직일 때마다 다시 잡으면 천천히 계속 움직이는 동안 열리지 않는다.
- 노치 없는 화면이면 주 화면(`NSScreen.screens.first`)에 가상 노치를 그린다. `NSScreen.main`은 키 윈도우가 있는 화면이라 앱을 오갈 때 바뀐다. 메뉴바가 숨으면(전체화면) 닫힌 가상 노치를 그리지 않는다. 메뉴바가 보이는지는 창 목록에서 Window Server의 "Menubar" 창(레이어 24)이 그 화면 맨 위에 있는지로 본다 (화면 기록 권한 없이 읽힌다. 이 맥의 외장 모니터에서 보이는 상태는 확인, 전체화면 상태는 아직).
- 알림 칸은 하나다. 경고(과열·메모리·배터리)는 정보성 알림을 밀어내고, 정보성 알림은 경고가 끝날 때까지 기다린다. 경고끼리는 차례로 띄운다.

## 메뉴바 아이콘 (macOS 26)

- 상태 아이콘 창은 전부 "제어 센터" 프로세스 소유로 보여서, 창 목록만으로는 어느 앱 아이콘인지 알 수 없다. 그래서 앱마다 손쉬운 사용 API의 `AXExtrasMenuBar`로 아이콘 위치를 읽는다.
- 아이콘은 `AXPress`로 누른다. 마우스는 움직이지 않는다. 화면 크기·비율에 따라 깨지는 방식은 쓰지 않기로 했다.
- 화면 밖에 있는 아이콘에 `AXPress`를 하면 메뉴도 화면 밖(x=-3798)에서 열린다. 그래서 잠깐 숨기기를 풀고 누른 뒤, 그 앱의 메뉴 창이 닫히면 다시 숨긴다.
  - 화면 밖인지는 목록을 읽을 때가 아니라 누르기 직전의 AX 위치로 본다 (정리 모드에서 고르면 그사이 구분자가 다시 접힌다).
  - 메뉴 창은 누르기 직전에 그 앱이 가진 창 번호를 적어 두고, 그 뒤 새로 생긴 레이어 > 0 창만 메뉴로 본다. 예전엔 원래 있던 창(레이어 25)도 메뉴로 봐서 최대 10분 동안 펼쳐진 채 0.3초마다 창 목록을 읽었다.
- 저장된 숨기기 상태는 아이콘 창이 자리를 잡은 뒤 ⌄가 구분자 오른쪽에 있을 때만 다시 켠다. 아니면 ⌄까지 화면 밖으로 밀린다.
- 숨기기는 구분자(`|`) 길이를 10000으로 늘려 왼쪽 아이콘을 화면 밖으로 밀어내는 방식이다. 길이를 노치 가장자리에 맞추는 방식은 macOS가 아이콘 순서를 섞어서 버렸다.
- 메뉴바가 넘치면(아이콘이 새로 생기는 등) macOS 26이 아이콘 순서를 스스로 섞는다. 실제 메뉴바에 상태 아이콘을 늘리는 실험은 하지 않는다.
- 가려짐 판정: 화면 안에 다 들어오지 않거나, 노치 오른쪽 끝보다 왼쪽에서 시작하거나, 구분자 왼쪽에 있으면 가려진 것으로 본다.

## 센서

| 값 | 읽는 곳 | 메모 |
|---|---|---|
| CPU | `host_processor_info` | 코어별 tick 차이 |
| 메모리 | `host_statistics64` | |
| GPU 사용률 | IOAccelerator `PerformanceStatistics` › `Device Utilization %` | 활성 상태 보기와 같은 값 |
| 네트워크 | sysctl `NET_RT_IFLIST2` | 64비트 카운터. `en*`만 센다 (VPN이 같은 트래픽을 두 번 세지 않도록). 인터페이스마다 따로 뺀다 |
| 디스크 속도 | IOBlockStorageDriver `Statistics` | 장치(레지스트리 번호)마다 따로 뺀다. 부모가 `…DiskImage…`인 DMG는 빼서 두 번 세지 않는다 |
| 디스크 여유 | `volumeAvailableCapacityForImportantUsage` | Finder와 같은 기준. 느려서 1분에 한 번 |
| 시스템 전력 | SMC `PSTR` | 실시간. 배터리 레지스트리 값은 1분에 한 번 정도만 바뀐다 |
| 어댑터 입력 | SMC `PDTR` | |
| 구성요소 전력 | IOReport "Energy Model" (`dlopen`) | CPU·GPU·ANE·메모리(DRAM+DCS+AMCC)·DISP·SoC 기타(AFR+FAB). 단위가 mJ/uJ/nJ로 섞여 있다. 합계는 SMC의 SoC 레일(`PHPS`)과 거의 같다 (M5 Max에서 91.9W / 92.6W). DISP는 디스플레이 컨트롤러뿐이고 백라이트는 안 들어간다 |
| 온도 | SMC `Tp*`(CPU), `Tg*`(GPU), `TH0x`(SSD), `TB*T`(배터리) | GPU 키는 84개라 고르게 8개만 읽는다 |
| 팬 | SMC `F{n}Ac` / `F{n}Mn` / `F{n}Mx` | 현재 / 최소 / 최대 RPM |
| 배터리 | AppleSmartBattery 레지스트리 | 10초에 한 번, 충전기를 꽂거나 빼면 바로. 어댑터 정격도 그때 같이 |

- 누적 카운터의 속도(네트워크·디스크)는 장치마다 따로 빼고(`CounterRate`), 줄어든 카운터와 새 장치는 이번엔 0으로 본다. 합계로 빼던 때는 외장 디스크·USB 이더넷을 빼면 UInt64가 거꾸로 넘쳐 1.8e19 B/s가 기록 파일에 남았다 (이 맥의 기록에도 17개 있었다. 불러올 때 100GB/s 넘는 네트워크 값은 지운다).
- 속도의 dt는 잠자기를 포함하는 단조 시계(`CLOCK_MONOTONIC_RAW`)로 재고, 10초(IOReport 30초)보다 길면 그 사이 평균은 버린다. 잠자기 뒤 첫 값이 0에 가깝게 기록되지 않게.
- 센서는 serial queue에서 읽고 결과만 메인에 넘긴다. IOReport 약 4ms, 온도 35개 약 5ms, 앱 목록 약 1.5ms라 메인에서 읽으면 120Hz 한 프레임(8.3ms)을 넘길 수 있다. 앞 측정이 안 끝났으면 다음 측정은 건너뛴다.

## 앱별 사용량 (앱 탭)

- `proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V6)`로 읽는다. 다른 계정 프로세스는 EPERM이라 내 계정 것만 읽힌다. 이 맥에서는 1004개 중 637개였고, 한 번 훑는 데 2.4ms 걸렸다.
- `ri_user_time`·`ri_system_time`은 나노초가 아니라 mach 시간 단위다. Apple Silicon에서는 125/3을 곱해야 ns가 된다. `ps`의 누적 CPU 시간과 맞춰 확인했다.
- `ri_energy_nj`는 프로세스가 쓴 CPU 에너지(nJ)이고 GPU는 들어가지 않는다. `ri_phys_footprint`는 활성 상태 보기의 '메모리'와 같은 값이다.
- 앱으로 묶는 기준은 실행 파일 경로의 가장 바깥 `.app`이다 (크롬 도우미 → Google Chrome). 앱 밖 프로세스는 argv[0](`KERN_PROCARGS2`)의 첫 단어를 이름으로 쓴다. 실행 파일 이름이 `2.1.3` 같은 버전 번호인 CLI는 위 폴더 이름을 쓴다 (`…/tool/versions/2.1.3` → `tool`).
- 앱 탭을 보고 있을 때만 2초마다 잰다.

## 경고 알림

- 과열은 `ProcessInfo.thermalStateDidChangeNotification`(serious/critical), 메모리는 `DispatchSource.makeMemoryPressureSource`(warning/critical), 배터리는 기존 전원 알림(IOPS)에서 20%·10%를 지날 때 띄운다.
- 모두 시스템이 알려주는 이벤트라 따로 측정하지 않는다. 같은 종류는 10분에 한 번만 띄우고, 더 심해지면 바로 띄운다.

## SMC

- C의 `SMCKeyData_t`는 80바이트다. Swift 구조체는 꼬리 패딩 자리에 다음 필드를 넣어버려서, `KeyInfo` 뒤에 3바이트 패딩을 직접 넣어야 크기가 맞는다. 안 넣으면 모든 키가 "없음"으로 나온다.
- 쓰기는 root만 된다. 아니면 `0xe00002c1`(kIOReturnNotPrivileged).
- M5 Max 팬 키: 모드 `F{n}md`(소문자, ui8, 0=자동 1=수동), 목표 RPM `F{n}Tg`(flt). `Ftst`와 `F{n}Md`는 없다.

## 팬 도우미

- launchd 데몬(`MachServices`)과 `NSXPCConnection(.privileged)`로 통신한다. 설치할 때 앱의 지정 요구사항(designated requirement)을 `--allow-requirement`로 넘기고, 도우미는 그것을 만족하는 연결만 받는다: 받을 때 pid로 한 번 걸러 로그를 남기고, 실제로는 `setCodeSigningRequirement`가 메시지마다 확인한다. 예전엔 실행 파일 경로만 봐서 같은 사용자의 아무 프로세스가 팬을 멈출 수 있었다.
  - 인증서 서명이면 요구사항이 identifier + 인증서라 다시 빌드하거나 옮겨도 같다. ad-hoc 서명이면 `cdhash H"…"`라 그 빌드에만 맞아서, ad-hoc 릴리스는 업데이트할 때마다 도우미를 다시 설치해야 한다.
- 안전장치: 앱 연결이 끊기거나, 앱 신호가 20초 동안 없거나, CPU가 95°C를 넘거나, 도우미가 켜지거나 꺼질 때 자동으로 되돌린다.
  - 20초는 잠자는 동안 멈추는 시계(`DispatchTime`, uptime)로 잰다. 벽시계로 재면 깨어난 직후 시간이 지난 것으로 보고 되돌렸다.
  - 자동으로 되돌리기(SMC 모드 키에 0 쓰기)가 실패하면 수동 상태로 남겨 두고 watchdog(2초)이 될 때까지 다시 시도한다. 예전엔 결과를 버려서 팬이 멈춘 채 남을 수 있었다.
  - keepAlive 답으로 지금도 수동인지, 온도 한계로 되돌렸는지 알려 준다. 앱은 5초마다와 깨어날 때 묻고, 온도 한계였으면 자동으로 두고 알리며, 아니면 지금 모드를 다시 적용한다.
- 도우미가 죽으면 launchd가 다시 띄운다(`KeepAlive: {Crashed: true}`). 시작할 때 팬을 자동으로 돌려놓으므로, 앱 없이 수동으로 남지 않는다. SIGTERM을 받으면 queue 안에서 되돌리고 바로 끝내서, 줄 서 있던 설정이 그 뒤에 수동으로 바꾸지 못한다.
- 설치는 `osascript`의 `with administrator privileges`로 한다. 관리자 셸이 `~/Documents` 같은 개인정보 보호 폴더를 읽지 못할 수 있어서 도우미를 먼저 사용자 임시 폴더에 둔다. 암호 창이 떠 있는 동안 그 파일이 바뀔 수 있으므로, 관리자 셸은 `mktemp`로 만든 root 폴더에 복사한 뒤 `codesign --verify -R '=<요구사항>'`으로 앱이 미리 잰 서명과 같은지 확인하고 설치한다. 설치 명령은 스크립트 파일 없이 바로 넘기고, launchd plist는 base64로 명령 안에 넣는다. 도우미의 서명은 번들 안 파일에서 읽으므로, 그 전에 번들 전체가 실행 중인 앱의 서명 그대로인지(`SecStaticCodeCheckValidity`, 안쪽 코드까지) 확인한다. 번들 안 도우미만 바꿔치기하면 여기서 걸린다 (복사본으로 확인). root가 필요한 단계 앞까지는 단위 테스트가 실제로 돌려 본다 (osascript를 거쳐서도).
- 규약 v2(10/29): 퍼센트 대신 RPM을 받는다. 팬마다 최대가 달라서(팬 1 5349, 팬 2 5777, 최소 1350) 퍼센트로는 같은 속도를 맞출 수 없기 때문이다.
- 규약 v3(10/29): 팬별 RPM 배열을 받는다 (`setFanSpeeds`, 값이 모자라면 마지막 값을 나머지 팬에). 0은 멈춤. 배열 인자는 XPC 인터페이스에 `setClasses`로 NSArray·NSNumber를 알려줘야 해서 앱과 도우미가 `FanHelper.makeInterface()`를 같이 쓴다.
- 규약 v4(10/31): `keepAlive`가 상태를 돌려주고, 연결을 코드 서명으로 확인한다.
- 도우미 버전은 launchd plist의 실행 인자(`--helper-version`)에 적어 둔다. 앱은 plist만 읽고도(XPC 연결 없이) 버전이 맞는지 알 수 있다.
- M5 Max에서 수동 RPM 제어가 동작한다: v2로 3600·5777·1400 등을 줬을 때 8초 확인에서 실패가 없었고(10/29 09:42), 온도별 규칙으로 2700 RPM이 걸렸다가 앱 종료 때 자동으로 돌아간 기록도 있다.

## 팬 조절 (앱)

- 모드: 자동 · 고정(팬별 RPM, 저장한 속도, 멈춤) · 온도별(30~100°C 여덟 점 커브). 설정은 UserDefaults `fan.*`에 둔다. 예전 단일 값 `fan.fixedRPM`은 처음 한 번 읽어서 옮긴다.
- 온도별: 곡선(점 사이 직선 보간)·계단(아래 점 값 유지). 팬 최소보다 낮은 값(0)은 그 구간을 macOS 자동으로 둔다는 뜻이다. 식는 중에는 `curve(온도 + 3°C)`와 지금 속도 중 작은 값을 써서 3°C 히스테리시스를 둔다. 기준 온도는 CPU·GPU 평균 중 높은 값.
- 반응 속도: 슬라이더를 끄는 동안 0.2초마다 도우미에 보낸다 (손을 떼면 바로 한 번 더). 온도·팬 탭을 보는 동안은 팬 RPM만 1초마다 따로 읽는다 (키 3개, 0.3~0.5ms). 팬 자체가 목표 속도까지 올라가는 데는 몇 초 걸린다.
- 커브는 항상 오른쪽으로 갈수록 같거나 높다. 점 하나를 바꾸면 더 뜨거운 점은 `max(원래 값, 새 값)`, 더 시원한 점은 `min(원래 값, 새 값)`으로 맞춘다. 끌기 시작할 때의 커브를 기준으로 계산해서, 다시 내리면 밀려난 점들이 제자리로 돌아온다. 저장된 커브도 불러올 때 오름차순으로 정리한다.
- M5 Max에서 멈춤(0 RPM)도 받아들이는 것으로 보인다: 10/29 낮에 4700 RPM → 멈춤을 여러 번 했는데 8초 확인 실패가 없었다.
- 도우미 연결이 끊기면(도우미 재시작 등, XPC 오류 4097) 다음 온도 측정 때 지금 모드를 다시 적용한다. 옛 연결의 알림이 늦게 와도 새 연결을 지우지 않게 어느 연결인지(`===`) 확인한다. 도우미가 거절하거나, 연결할 수 없거나(4099), 팬이 8초 안에 따라오지 않으면 모드를 자동으로 바꾸고 멈춘다 (2초마다 다시 시도하지 않게).
- 8초 확인은 하나만 잡아 두고, 그때 걸려 있는 목표가 바뀐 지 8초가 안 됐으면 그만큼 더 기다리되 처음부터 24초 넘게는 미루지 않는다. 팬이 지금 목표나 최근 30초 안에 걸었던 목표 근처에 있으면 통과다 (온도별 모드에서 앞 목표를 따라가는 중일 수 있다). 예전엔 적용할 때마다 확인을 취소해서 온도별 모드에서는 확인이 영영 안 돌았다.
- 설정을 보낼 때마다 번호를 올리고, 그 전에 보낸 keepAlive나 설정의 답은 무시한다. 늦게 온 "온도 한계로 되돌림" 답이 그 뒤에 보낸 새 설정을 자동으로 뒤집으면 도우미는 수동인데 앱은 자동으로 보인다.
- 앱이 스스로 끊은 연결(재설치·제거·중단 뒤 정리)에서 오는 오류는 무시한다. 안 그러면 "다시 설치해보세요"가 뜨고 모드가 자동으로 바뀐다.
- 온도별 히스테리시스의 기준은 온도별 모드가 마지막으로 고른 RPM이다. 지금 적용된 값을 쓰면 고정에서 온도별로 바꿀 때 고정 속도가 기준이 됐다.
- 슬라이더나 커브를 끄는 중에 대시보드가 닫히면(마우스가 노치 밖으로 나감) 그때 값으로 저장한다.
- 앱을 끌 때 자동으로 되돌리는 요청은 1초까지만 기다린다. osascript의 오류 출력은 끝나기를 기다리지 않고 읽으면서 기다린다 (64KB 넘으면 서로 기다리며 멈춘다).
- 노치 패널은 키보드 입력을 받지 않아서, 숫자는 직접 그린 슬라이더와 그래프 끌기로 바꾼다. 시스템 슬라이더(NSSlider)는 `--render`(ImageRenderer)에서 노란 금지 표시로만 나온다.
- SwiftUI `Text("\(정수) RPM")`은 지역 설정에 따라 "2,800"처럼 쉼표가 들어간다. 숫자는 `String`으로 만들어서 넘긴다.

## 코드 에이전트 (에이전트 탭)

- 화면은 tmux `capture-pane -p -e`(색 코드 포함)로, Terminal.app은 AppleScript `contents`(글자만)로 읽는다. 상태는 화면 맨 아래만 본다: 위쪽 대화 기록에도 번호 목록이나 지난 질문이 남아 있기 때문이다. 번호 목록은 커서(❯ › →)가 있거나 바로 아래에 "Enter to …/Esc to cancel" 안내가 있을 때만 선택지로 본다.
- 고르는 법: Claude Code와 Codex 모두 번호 글자 하나만 보내면 바로 골라진다 (Enter를 같이 보내면 다음 질문까지 넘어갈 수 있다). Claude의 폴더 신뢰 창과 pi 모델 목록은 번호가 없어서 화살표로 옮긴 뒤 Enter (tmux만 된다).
- Codex(와 Claude Code)는 글자가 한꺼번에 들어오면 붙여넣기로 보고 바로 뒤의 Enter를 줄바꿈으로 받는다. 글자를 보낸 뒤 0.15초 쉬고 Enter를 보낸다 (`TmuxBridge.send`). 쉬지 않으면 입력창에 글자만 남는다 (10/31 직접 확인).
- 작업 중 표시: Claude · Codex는 "esc to interrupt", pi는 점자 스피너 다음 "Working", OpenCode는 "esc interrupt". Claude의 스피너 줄은 처음 1초쯤 괄호 없이 "· Warping…"만 나온다.
- Codex 입력창의 회색 예시 글("› Summarize recent commits")은 흐린 글씨(SGR 2)로만 사용자가 친 글과 구분된다. Terminal.app은 색을 못 읽어서 구분할 수 없다 (상태는 어차피 '입력 기다림'이라 상관없다).
- pi는 Node 스크립트인데 `process.title`을 "pi"로 바꿔서 실행 인자 자리가 "pi" 하나로 덮인다. 그래서 인터프리터의 argv[0]이 에이전트 이름이면 그 에이전트로 본다.
- `devname()`(tty 장치 번호 → 이름)은 /dev를 훑어서 느리다. 3초마다 에이전트 15개에 부르니 대시보드가 닫혀 있을 때 CPU의 대부분이 여기였다 (1.2% → 0.7%). 이름은 기억해 둔다.
- 훅: Claude Code는 이벤트 JSON을 stdin으로, Codex notify는 JSON을 마지막 인자로 준다. 훅 프로세스는 셸(`sh -c`)을 거쳐 뜨므로 부모를 몇 단계 올라가 에이전트 프로세스의 tty · pid를 찾고, 분산 알림(`DistributedNotificationCenter`)으로 앱에 넘긴다. Claude는 UserPromptSubmit · SessionStart 훅의 stdout을 대화에 넣으므로 아무것도 출력하지 않는다. Codex의 notify는 프로그램 하나만 받는다 (이 맥은 Codex Computer Use가 쓰고 있다).
- SwiftUI `.clipped()`는 그림만 자르고 누르는 자리(hit test)는 자르지 않는다. 맨 아래에 맞춰 그리는 긴 터미널 미리보기가 위로 넘쳐서 위쪽 버튼들의 클릭을 먹었다 (10/31). 보기만 하는 큰 글자는 `.allowsHitTesting(false)`.
- 노치 클릭은 `Cheoma --click-test`로 확인한다: 같은 패널을 화면 밖에 띄우고 `NSEvent.mouseEvent`를 `panel.sendEvent`로 바로 넣는다 (마우스 커서는 그대로). `--grid`는 버튼 둘레를 촘촘히, `--key`는 키 창이 될 수 있는 상태로. 실제로 터미널에 글자를 보내는 버튼(선택지 · 보내기)은 누르지 않는다.
- Claude 구독 한도(5시간 · 주간)는 기록 파일에 없고 상태 줄 명령의 입력 JSON에만 있다: `rate_limits.five_hour/seven_day.used_percentage, resets_at`(초). 세션에서 첫 요청을 보내기 전에는 `rate_limits`가 아예 없다 (10/31 확인). 상태 줄 명령은 자주 불리는데 Cheoma 실행 파일은 처음만 0.4초, 그 뒤 0.01초.
- Claude Code는 돌고 있는 프로세스마다 `<설정 폴더>/sessions/<pid>.json`을 적는다: sessionId, cwd, status(`idle` 입력 기다림 · `busy` 작업 중 · `waiting` 권한 묻기), statusUpdatedAt(ms). 어느 설정 폴더에 있는지로 계정도 안다. 같은 폴더에서 여러 세션을 띄워도 이걸로 구분한다.
- `sessions/<pid>.json`의 status는 한 차례 내내 `busy`로 남는다 (도구를 돌리는 사이에도). 화면(입력창은 일하는 중에도 보인다)이나 tty 출력으로 판단하면 작업 중 ↔ 입력 기다림을 오간다. 차례가 끝나 셸이 남아 있으면 `shell`이 몇 시간씩 남는다 (10/31 확인).
- Claude Code는 손대지 않아도 혼자 돈다: 기다리는 동안 프롬프트 캐시가 끝나기 전에 대화를 줄이고("Compacted while idle … `idleCompaction`: false로 끔"), 돌아오면 요약(`away_summary`, /config에서 recap 끔)을 만든다. 이 맥 기록에서 이틀 동안 대화 줄이기 22번, 요약 144번. 이때는 UserPromptSubmit · Stop 훅이 오지 않는다.
- 계정 정보: 기본 폴더(~/.claude)의 로그인은 홈의 `~/.claude.json`, 다른 폴더는 `<폴더>/.claude.json`의 `oauthAccount`(emailAddress, planDisplayName, organizationRateLimitTier "default_claude_max_20x"). `cachedUsageUtilization.utilization.five_hour/seven_day`에 Claude Code가 받아 둔 한도(utilization %, resets_at은 소수점 여섯 자리 ISO 문자열)와 `fetchedAtMs`. 그래서 기본 계정을 `CLAUDE_CONFIG_DIR=~/.claude`로 띄우면 로그인이 안 된 것처럼 된다 (이 변수를 붙이지 않는다).
- 다른 계정으로 이어서 하기: `<설정 폴더>/projects/<작업 폴더 이름>/<세션 ID>.jsonl`을 다른 계정의 같은 자리로 복사하고 `CLAUDE_CONFIG_DIR=… claude --resume <ID>` (10/31 확인: 예전 대화가 그대로 나온다). 그 계정에서 처음 여는 폴더면 신뢰 창이 먼저 뜬다. Codex 로그인은 `~/.codex/auth.json`(auth_mode, id_token 안의 email · chatgpt_plan_type).
- 사용량: Codex 한도는 rollout 기록의 `token_count` 이벤트(rate_limits)에서, Claude 비용은 기록의 토큰 수와 cost-state로 배운 모델별 단가로 계산한다. 처음 읽기는 릴리스 빌드에서 약 0.3초(48시간치), 그 뒤로는 바뀐 부분만 읽어 약 12ms.

## 성능

`Cheoma --bench [초] [탭]`으로 잰다. CPU 사용률과 함께 초당 그래프를 그린 횟수, 창 배치(NSHostingView.layout) 횟수를 찍는다. 릴리스 빌드 기준:

| 상황 | 처음 (10/29) | 10/29 | 10/30 (v0.1.0) | 10/31 |
|---|---|---|---|---|
| 대시보드 닫힘 | 0.59% | 0.2% | 0.2~0.3% | 0.3% |
| 개요 탭 | 15% | 1.1% | 1.5% | 1.4% |
| 그래프 탭 (1분) | 13% | 1.0% | **110%** | 4.7% |
| 그래프 탭 (10분·1시간·24시간) | | | 1.0% | 1.4~1.8% |
| 온도 탭 | 8.8% | 0.9% | 1.2% | 1.3% |
| 팬 탭 | 1.8% | 0.8% | 1.0% | 0.9% |
| 앱 탭 | 2.3% | 1.4% | 1.9% | 1.5% |

- 10/29의 원인은 그래프의 `TimelineView(.animation(minimumInterval:))`였다. 그림은 간격대로만 다시 그려도, 이 일정은 화면 주사율(120Hz)마다 깨어나서 SwiftUI가 대시보드 전체를 다시 계산한다.
- 그 대신 쓴 `TimelineView(.periodic(from:by:))`도 macOS 26에서는 간격이 짧으면(0.25초에서 재현, 0.5초는 23%) 창 배치를 쉬지 않고 되풀이했다: 그래프 탭 1분 구간(간격 약 0.19초)에서 배치가 초당 3~4만 번, CPU 110%. 1초 간격인 머리줄 시계도 초당 1600번 배치했다 (CPU는 1% 남짓이라 티가 안 났다). 그래서 TimelineView를 쓰지 않는다:
  - 흐르는 그래프는 `GraphClock`(ObservableObject, `.task`에서 `Task.sleep`)이 간다. 긴 간격(24시간 구간은 약 5분)도 최대 1초씩 자면서 간격이 바뀌었는지 보고, 구간을 바꾸면 바로 지금 시각으로 다시 그린다. 한 탭의 그래프 네 개가 시계 하나를 같이 써서 같은 순간에 다시 그려지므로 배치도 한 번이다 (그래프 탭 1분: 그리기 초당 24번, 배치 6번).
  - 머리줄 시계는 시·분만 보여서 `.everyMinute`.
  - 작은 그래프(60초를 64pt)는 타이머 없이 새 값이 들어올 때(1초)만 다시 그린다.
- 큰 그래프는 한 포인트 움직일 때마다 다시 그린다.
- 찾은 방법: `sample <pid>`에서 메인 스레드가 `NSHostingView.layout` → `ViewGraph.beginNextUpdate` → `propagate_dirty`만 돌고 있었고, 우리 body는 거의 다시 계산되지 않았다. 호스팅 뷰의 `layout()`을 세어 보니 초당 수만 번이었다.
- 기록에 한 번 더하기: 그래프가 예전 기록을 들고 있으면 바뀌는 항목의 배열(1시간치 3600점)을 통째로 복사하지만, 항목 하나에 0.003ms(tick당 약 0.03ms)라 그대로 둔다.
- 센서 한 번 읽기: IOReport(구성요소별 전력) 4ms, 온도 35개 4.5~6.5ms(SMC 키 하나에 약 0.19ms), 앱별 사용량 1.2ms, 나머지는 0.03ms 이하. 그래서 온도와 IOReport는 열려 있으면 2초, 닫혀 있으면 4초마다만 읽는다. 에너지는 누적값의 차이라 간격이 길어도 그 사이 평균은 정확하다.
- IOReport는 "Energy Model" 그룹 전체(수백 채널)가 아니라 쓰는 채널(CPU·GPU·ANE·DRAM·DCS·AMCC·DISP·AFR·FAB)만 구독하고, 채널 이름은 처음 한 번만 해석한다 (예전엔 매번 정규식을 새로 만들었다).
- 노치 그림자는 검은 모양에만 단다. 원인은 아니었지만 내용 전체에 다는 것보다 낫다.
- 닫은 창도 SwiftUI 뷰는 계속 돈다 (11/20): 설정 창을 한 번 열었다 닫으면 대기 CPU가 2~4%였다 (켠 지 15시간 47분, 20초 `sample`에서 일한 0.5초 중 0.25~0.3초가 닫힌 설정 창의 `SettingsView.body`).
  - `isReleasedWhenClosed = false`로 창을 들고 있으면 `NSHostingController`의 뷰가 `@ObservedObject`를 계속 구독한다. 화면에 없어도 탭 네 개를 다 다시 계산한다 (`AppKitTabView`가 탭마다 크기를 잰다). 그래서 닫을 때 창을 놓고 다음에 새로 만든다.
  - `@Published`는 같은 값을 넣어도 `objectWillChange`를 보낸다. `AgentStore.apply`가 3초마다 `sessions`를 새로 대입해서 바뀐 게 없어도 다시 그렸다. 화면을 새로 읽으면 `TerminalScreen.capturedAt`만 달라져도 다른 값이 되므로 글자가 같으면 예전 것을 둔다. 대신 "5분 전" 같은 글자가 멈추지 않게 30초마다 한 번은 보낸다.
  - 다시 그릴 때마다 `Picker`(`AgentKind` 태그)가 만드는 SwiftUI 내부 객체(`TagIndexProjection` · 딕셔너리 둘)가 풀리지 않고 쌓였다: `heap <pid>`로 33초 사이 12,047 → 12,057개(3초에 하나), 약 4MB. 안 그리면 안 쌓인다.
  - 그때 메모리: footprint 156~167MB, 살아 있는 힙 69MB, 나머지 약 77MB는 풀렸지만 malloc이 들고 있는 것. 최고 454MB는 원인을 못 찾았다 (켤 때 Claude 기록 2,904개 · 3.5GB를 처음 훑을 때로 짐작).
- 그 전(10/28): 대기 CPU 3~4% → 0.5~0.8%. 원인은 디스크 여유 공간 계산, GPU 온도 키 84개, 배터리 레지스트리 전체 읽기였다.

## 빌드 / 권한

- 개발 빌드는 키체인의 Apple Development 인증서로 서명한다 (10/30부터). ad-hoc 서명이면 빌드할 때마다 서명이 바뀌어서 손쉬운 사용 권한이 초기화된다. 시스템 설정에는 켜져 있는데 앱은 권한이 없다고 나오면 이 경우다 (`tccutil reset Accessibility io.github.m-kim77.cheoma` 후 다시 허용).
- 단위 테스트는 `scripts/test.sh`. XCTest는 Xcode에만 있어서 명령줄 도구가 선택돼 있으면 `DEVELOPER_DIR`을 Xcode로 바꿔 `swift test`를 돌린다. 메인 액터 코드(FanController, NotchModel)를 부르는 테스트 클래스는 `@MainActor`를 붙인다.
- `-strict-concurrency=complete`로 빌드해도 warning이 없다 (10/31).
- hardened runtime(배포 조건)으로 서명해도 SMC, IOReport(`dlopen("/usr/lib/libIOReport.dylib")`, 시스템 라이브러리라 라이브러리 검증 통과)가 동작한다 (10/29 확인).
- 터미널에 화면 기록 권한이 없어서, UI는 `--render`(ImageRenderer로 PNG 저장)로 확인한다.
- 빌드는 `nice`와 동시 작업 2개로 돌린다 (팬 소음을 줄이려고).
- Swift는 15바이트 이하의 짧은 문자열 리터럴을 코드 안에 바로 넣는다. 그래서 바이너리를 `grep`해도 짧은 문자열은 안 나온다. 새 코드가 빌드에 들어갔는지 볼 때는 긴 문자열로 찾는다.
- 실행 중인 앱은 `kill -TERM <pid>`로 끄면 기록을 저장하고 끝난다. `caffeinate -w <pid>`로 꺼질 때까지 기다린 뒤 새로 설치하고 `open`한다.

## 노치 확장 조사 (2026-11-23)

아직 만들지 않은 기능이 macOS 26.7에서 되는지 알아본 것.

- **지금 재생 중**: macOS 15.4부터 `mediaremoted`가 엔타이틀먼트를 확인해서, 일반 앱은 MediaRemote 비공개 프레임워크로 재생 정보를 못 읽는다. `/usr/bin/perl`은 그 권한이 있어서, perl로 작은 dylib를 불러 읽는 방식(오픈 소스 `ungive/mediaremote-adapter`. 가져다 쓰기 전에 라이선스를 확인한다)이 15.4 이상에서도 동작한다고 알려져 있다. 26.1에서 읽기는 되지만 재생 명령 보내기는 막혔다는 제보가 하나 있다 (확인 못 함). 명령이 막히면 미디어 키 이벤트(`NX_KEYTYPE_PLAY` 등)로 대신한다. Apple이 또 막을 수 있으니 실패하면 귀를 숨기고, Music·Spotify는 AppleScript로 되돌아간다. 브라우저의 유튜브도 Media Session으로 "지금 재생"에 올라오니 따로 할 일이 없다.
- **AirDrop 받기**: 받기 요청에 끼어드는 공개 API는 없다. 요청은 알림 센터 알림으로 뜨므로, 알림 센터 프로세스(`com.apple.notificationcenterui`)에 AX 관찰자를 달아 새 알림 창을 보고, 제목이 AirDrop이면 노치에 띄우고 "수락" 버튼을 `AXPress`로 누르는 방법뿐이다. 이미 가진 손쉬운 사용 권한으로 되지만, 알림 창 구조·버튼 이름(언어마다 다름)이 macOS 버전마다 바뀔 수 있다. 실제 AirDrop을 받아 AX 트리를 떠 봐야 한다. 받은 뒤는 다운로드 폴더를 FSEvents로 보고 AirDrop으로 온 파일인지는 확장 속성(`kMDItemWhereFroms`, 격리 속성의 보낸 앱)으로 가릴 수 있는지 아직 확인 못 했다.
- **실행기**: macOS 26 Spotlight가 앱·파일·동작·클립보드 기록(⌘1~4)과 빠른 키를 갖게 돼서, 그대로 따라 만들면 차이가 없다. Cheoma만 할 수 있는 것(에이전트에 답 보내기, 팬·타이머, 로컬 LLM에 묻기)을 앞에 둔다. 앱 목록은 `NSMetadataQuery`(`kMDItemContentType == com.apple.application-bundle`), 단축키는 워크트리의 Carbon `HotKey`(손쉬운 사용 권한 필요 없음), 창은 포커스를 빼앗지 않는 `NSPanel`(`.nonactivatingPanel`)로, 글자를 칠 때만 key window가 되게 한다.
- **로컬 LLM**: Foundation Models는 이 맥에서 `available`, `supportsLocale(ko-KR) == true`, 한 문장 답 1.7초. 다만 "노치"를 하드웨어로 알아듣는 등 지식이 약하고 컨텍스트가 4,096토큰이라, 도구 고르기(타이머 맞춰 · 팬 올려 · 앱 열어)와 짧은 요약에 쓴다. 도구는 3~5개 넘게 주지 말라는 게 Apple 권고다. 긴 대화·질문은 LM Studio·Ollama(`LocalModels.swift`가 이미 찾음)의 OpenAI 호환 API로 보내거나, `mlx-swift-lm`으로 앱 안에 모델을 넣는다 (Qwen3 계열 도구 호출 지원). 128GB 맥이라 큰 모델도 되지만 배포판 사용자를 생각해 기본은 Foundation Models.
- **음성**: `SpeechTranscriber`는 이 맥에서 한국어를 지원하고 `ko_KR` 모델이 이미 설치돼 있다. 마이크 권한이 새로 필요하다. "시리야" 같은 호출어는 늘 마이크를 켜 둬야 해서 하지 않고, 단축키를 누르고 말하는 방식으로 한다. 답을 읽어 줄 땐 `AVSpeechSynthesizer`.

## 음성 받아쓰기 · 음성으로 LLM (2026-11-23 조사)

Spokenly처럼 말한 걸 붙여넣는 것과, 말한 걸 바로 LLM·에이전트에 넣는 것. 구독(Claude · ChatGPT · Gemini)을 API 키 없이 쓸 수 있는지도 봤다. 회사 약관은 11월에 바뀐 것까지 원문으로 확인했다.

### 구독으로 LLM 쓰기

| | 앱이 직접 부르기 | 공식 CLI를 뒤에서 (`-p` · `exec`) | tmux의 대화형 CLI에 넣기 (지금 방식) |
|---|---|---|---|
| ChatGPT | **된다.** "Sign in with ChatGPT" 플랜 사용(2026-09 DevDay). 오픈 소스·로컬 앱은 신청 없이 된다 (`client_id=dynamic_agent_client`, PKCE, 127.0.0.1 콜백) | 된다. 로컬·비상업 앱은 `codex exec --json`, `codex app-server`(stdio JSON-RPC, 실험) 허용 | 된다 |
| Claude | 안 된다. 토큰을 꺼내 쓰는 건 금지이고 서버에서 막는다 | 회색, 배포 앱이면 금지 쪽. 로그인 도움말(11/22): "다른 사람을 위한 앱이면 API 키". 이용 정책(11/12): "소비자 구독으로 요청을 보내는 서비스" 금지 | 된다. 사용자가 자기 계정으로 수정 안 한 Claude Code를 쓰는 것 |
| Gemini · Antigravity | 안 된다. 다른 도구로 로그인 재사용 시 계정 정지 사례(2026-02) | 안 된다. FAQ: 제3자 앱이 `agy -p`를 감싸는 건 소비자 플랜에서 지원 안 함 | 사용자가 직접 한 말만. 프로그램이 만든 글 · 자동 Enter는 안 됨 (포럼 답변) |

- ChatGPT 플랜 사용의 조건: Go·Plus·Pro·Business. Responses API만, `stream: true` · `store: false` 필수, system 역할 대신 `instructions`. 음성 입력 · 전사 API는 안 된다. 한도는 Codex와 같은 "ChatGPT Work · Codex" 몫에서 나가고 앱별 주간 한도(%)가 있다. 화면에 "Continue with ChatGPT" 버튼, "Using ChatGPT plan" 표시, "Manage usage"(ChatGPT 설정 › 사용량) 링크를 둬야 한다. 유료 · 호스팅 앱은 대기 명단.
- Claude를 깨끗하게 쓰는 길: Max($100) · Ultra($200) · Team은 매달 API 크레딧이 있어서 Console API 키로 부르면 추가 비용이 없다 (Pro는 없음). 키는 Cheoma 키체인에 둔다. 뒤에서 `claude -p`를 쓰더라도 `--bare`는 구독 로그인을 안 읽어서 못 쓰고(`--safe-mode`를 쓴다), 문서에 "-p의 기본이 `--bare`가 된다"고 예고돼 있다. 첫 응답까지 3~6초(이슈 제보, 직접 재지 않음).
- Google AI Pro · Ultra에는 매달 Google Cloud 크레딧이 붙어서 AI Studio의 Gemini API 키로 쓸 수 있다 ($5 선결제 필요, 금액은 출처마다 다름). Gemini CLI는 2026-06-18부터 구독 사용자를 받지 않는다.
- 각 CLI에 자체 음성 입력이 생겼다: Claude Code `/voice`(한국어 `ko`, 한도에서 안 빠짐, 음성은 서버에서 전사), agy `/voice dictate`(F5), Copilot CLI. tmux에서 띄운 CLI 안에서 쓰는 거라 약관 걱정이 없다.
- 에이전트에 말 넣는 공식 통로: `codex queue --thread <ID> --message <글>`, `claude agents --json`(상태 읽기, `~/.claude/jobs`는 안정된 인터페이스가 아님). 없으면 지금처럼 tmux `paste-buffer -p`.
- 지금 코드에서 걸리는 것: `AntigravityQuota`의 `agy -p /usage`(모델은 안 부르지만 위 FAQ에 걸릴 수 있음), `~/.codex/auth.json`의 id_token을 읽는 것(밖으로 보내지는 않음, app-server `account/read` · `account/rateLimits/read`로 바꿀 수 있음).

### 받아쓰기 엔진 (한국어 + 영어 개발 용어)

- 이 맥에서 합성 음성(`say -v Yuna` 등)으로 쟀다. 실제 목소리보다 쉽다. 용어집(도커→Docker 등)을 양쪽에 똑같이 적용한 CER: whisper.cpp large-v3-turbo + 용어 프롬프트 **4.5%**, whisper.cpp 10.3%, SpeechTranscriber 18.4%, DictationTranscriber + contextualStrings 21.1%, DictationTranscriber 26.0%.
- Apple SpeechAnalyzer: 내려받을 것 없음(ko_KR 설치됨), 키를 뗀 뒤 최종 글까지 SpeechTranscriber 25~40ms, DictationTranscriber 100~230ms. SpeechTranscriber는 영어 용어를 한글로 쓰고 contextualStrings를 무시한다. contextualStrings는 100개 · 한두 단어까지. DictationTranscriber `.shortForm`은 파일 모드 ko_KR에서 빈 글을 낸다(스트리밍은 됨). `AssetInventory.status`는 앱이 locale을 예약해야 `.installed`가 된다.
- whisper.cpp(MIT): 9초에 0.34초, 메모리 약 0.93GB. `~/models/ggml-large-v3-turbo-q5_0.bin`(574MB)과 `/opt/homebrew/bin/whisper-cli` 1.9.5가 이미 있다.
- Qwen3-ASR(Apache-2.0, Swift 포트 speech-swift · mlx-audio-swift)는 자체 발표 FLEURS-ko CER 2.57이지만, 독립 비교(BuzzASR)에서는 Whisper-large-v3 5.72 대 Qwen3-ASR-1.7B 7.39. 실제 녹음으로 비교하기 전엔 기본으로 하지 않는다. Parakeet은 한국어가 없다. SenseVoice는 라이선스가 GPL과 맞지 않을 수 있다.
- 구독으로 전사하는 길은 없다 (ChatGPT 플랜은 전사 제외, Claude `/voice`는 Claude Code 안에서만). 전사는 로컬에서 한다.

### 단축키 · 마이크 · 붙여넣기

- 단축키: 오른쪽 ⌥ 누르고 있기를 기본으로 (flagsChanged, keyCode 61 + `NX_DEVICERALTKEYMASK`, 150~200ms 뒤 시작, 다른 키가 눌리면 취소). NSEvent 전역+로컬 모니터나 listen-only CGEventTap 모두 이미 있는 손쉬운 사용 권한으로 된다 (Apple DTS, 2026-05). Carbon `RegisterEventHotKey`는 키 떼기는 알지만 수식키 하나만으로는 못 건다. Fn은 이 맥에서 이모지 창(`TISGetFnUsageType` = 2)이고, 한국 사용자는 입력 전환에 많이 써서 선택지로만 둔다.
- 마이크: 지금 Cheoma는 hardened runtime인데 `com.apple.security.device.audio-input` 권한과 `NSMicrophoneUsageDescription`이 없어서 마이크가 조용히 막힌다. Speech 프레임워크를 쓰면 `NSSpeechRecognitionUsageDescription`도 있어야 한다. ad-hoc 릴리스는 업데이트마다 마이크 권한도 다시 받아야 한다. 블루투스 헤드셋 마이크를 열면 음질이 떨어지니 내장 마이크를 먼저 쓰고 키를 누르는 동안만 연다. macOS 26에서 블루투스 마이크로 `installTap`이 안 불린다는 제보가 있어 AUHAL이나 AVCaptureSession을 쓴다.
- 붙여넣기 순서: ① Cheoma 패널이 key면 Cheoma 입력란 ② Cheoma가 아는 tmux 에이전트 칸이면 `TmuxBridge.send` ③ 확인된 네이티브 앱이면 AX `kAXSelectedTextAttribute`로 쓰고 다시 읽어 확인 ④ 클립보드(transient · current-host 표시) + ⌘V. 2벌식에서도 ⌘V 키코드는 9로 맞다 ⑤ Chromium 155~156(이 맥에서는 Claude 데스크톱 Electron 45.3.3, Brave)은 ⌘V가 가끔 씹혀서 메뉴의 "붙여넣기"를 AX로 누른다. 메뉴는 "편집"/"수정"처럼 이름이 달라서 키 조합(⌘V)으로 찾는다.
- 한글 입력기(2벌식) 상태에서 유니코드 글자 치기는 위험하다. 조합 중인 글자가 있을 때 어떻게 되는지는 아직 시험 못 했다.
- 클립보드 되돌리기는 `accessBehavior == .alwaysAllow`일 때만, 내 것인지는 `changeCount` · types로 본다 (내용을 읽으면 macOS의 "다른 앱에서 붙여넣기" 경고가 뜰 수 있다. 이 맥에도 설정 항목이 있다). 만든 뒤에 알아낸 것은 아래 "받아쓰기 구현".
- 참고 코드: VoiceInk(GPL-3.0, 붙여넣기 · 선택 글 읽기 · 로컬 CLI 공급자), FluidVoice(GPL-3.0, 노치 UI · 명령 모드), OpenWhispr(MIT). VoiceInk의 메뉴 찾기는 영어 제목("Edit"/"Copy")이라 한국어 맥에서 안 된다.

### 다른 받아쓰기 앱

- 다들 갖춘 것: 누르고 말하기 + 두 번 눌러 계속 듣기, Esc 취소, 로컬·클라우드 엔진, 붙여넣고 클립보드 되돌리기, 마지막 결과 다시 붙이기, 용어집, 모드(프롬프트 + 선택 글 · 클립보드 · 앱 · 화면 글자, 앱별 자동 전환).
- 에이전트 쪽: Spokenly 2.18+ MCP(`ask_user_dictation`) · CLI · 동작, Superwhisper는 에이전트마다 훅 플러그인, Aqua "send it". 모두 에이전트마다 뭔가를 깔아야 한다. Cheoma는 이미 화면을 읽고 tmux로 보내서 설치 없이 된다 (음성으로 선택지 답하기, 계정 골라 에이전트 띄우기).
- 구독 로그인을 받는 받아쓰기 앱은 없다. API 키, 자체 모델, CLI 하위 프로세스(VoiceInk), 브라우저로 넘기기(`chatgpt.com/?q=`, `claude.ai/new?q=`, 채우기만 하고 보내지는 않음)뿐이다.
- 이 맥의 Spokenly는 App Store판 2.16.0(2026-01)이라 자동 붙여넣기 · MCP · CLI가 없다. 최신 직접 배포판은 2.35.16. ChatGPT 앱(`com.openai.codex`)에도 전역 받아쓰기가 있다.

### 받아쓰기 구현 (11/23)

조사 뒤 만든 것에서 알아낸 것. 코드는 `Sources/Cheoma/Dictation/`, 부품끼리의 약속은 `DictationModels.swift`.

- 흐름: 단축키를 누르면(armed) 바로 마이크를 열고 소리를 모아 둔다 (첫 음절). 0.15초 넘게 누르고 있으면(began) 그때 엔진을 시작하고 모은 소리를 차례대로 넘긴다. 톡 친 것 · ⌥← 같은 단축키는 엔진을 건드리지 않는다 (Apple 분석기를 ⌥마다 새로 만들지 않게). 키를 떼면 0.12초 더 듣고 마무리한다. 엔진 호출은 한 줄로 세운다: 앞 말의 finish가 끝나야 다음 말의 begin을 부르고, 그동안 새 말은 큐에 모은다.
- 블루투스 마이크가 기본 입력이면 began에서 연다 (누를 때마다 헤드셋이 통화 음질로 바뀌지 않게). 내장 마이크를 쓰도록 하면 AUHAL의 `kAudioOutputUnitProperty_CurrentDevice`를 엔진 시작 전에 바꾼다. 마이크가 2초 동안 버퍼를 하나도 안 주면 멈춘 것으로 본다 (macOS 26 블루투스에서 `installTap`이 안 불린다는 제보 대비).
- 엔진 시간 (이 맥, 합성 음성): DictationTranscriber 첫 중간 글 0.5초, 키를 뗀 뒤 최종 글 약 0.05초(섞어 말한 문장은 0.2~0.25초). whisper-cli는 말 하나마다 새로 띄워도 모델 포함 0.35~0.45초라 whisper-server를 쓰지 않는다 (서버는 0.12~0.15초지만 메모리를 계속 잡는다). Apple 기본은 DictationTranscriber: contextualStrings를 받고 첫 글이 SpeechTranscriber의 두 배 빠르다. 섞어 말한 개발 용어("GitHub에 push하고")는 여전히 whisper가 훨씬 낫다.
- `AppleSpeechEngine.prepare`는 ko-KR을 예약한다 (AssetInventory 예약 칸 5개 중 1개). `SpeechModels.endRetention()`은 프로세스 전체에 걸린다.
- whisper.cpp는 `--prompt`가 길면 앞을 자르고 끝을 남긴다. 그래서 용어를 중요한 순서로 고른 뒤 거꾸로 이어서 사용자 용어가 끝에 오게 한다 (500바이트).
- 용어집: 한글로 끝나는 패턴은 뒤에 조사 · 어미("를", "에서", "니까" …)가 오거나 글이 끝날 때만 바꾼다. "고랭지" → "Golang지", "러스트벨트" → "Rust벨트" 같은 오변환을 막는다. "자바라"는 구별할 수 없어 "Java라"가 된다.
- Esc: 듣는 동안만 `cgSessionEventTap` + `.defaultTap`(손쉬운 사용 권한으로 됨)을 달아 Esc를 삼킨다. 탭은 자기 스레드 · 자기 런루프에서 돌고, 삼킬지는 잠금으로 지킨 값으로 탭 스레드에서 바로 정한다. 메인 런루프에 두면 Cheoma가 바쁠 때 시스템 전체 키 입력이 늦어진다. 떼는 일도 탭 스레드에서 한다 (`CFRunLoopPerformBlock`: 끄기 → 소스 빼기 → 포트 무효 → 런루프 멈춤).
- 붙이기 전에 수식키가 모두 떨어질 때까지 기다린다 (⌥를 누른 채면 ⌘V가 ⌥⌘V가 된다). 다음 받아쓰기 단축키를 누르고 있으면 그 키를 뗄 때까지 기다리고, 끝내 안 떨어지면 클립보드에만 넣는다. 우리가 보낸 ⌘V에는 `eventSourceUserData` 표시를 달아 단축키 감시가 사용자 키로 보지 않는다.
- 클립보드 되돌리기 (`NSPasteboard.accessBehavior`): macOS 26은 처음에 `.default`(물어봄)라 읽으면 경고가 뜬다. 그래서 `.alwaysAllow`일 때만 떠 두고 되돌린다. 15.4~15.x는 경고를 띄우지 않아 `.default`도 허용으로 본다 (15.x 기계에서 확인은 못 함). 그림 · PDF · 파일 약속(promise) · 8MB 넘는 것 · Concealed · Transient · 1Password 항목은 떠 두지 않는다 (다시 써 넣으면 암호 관리자의 자동 지우기가 무력해지고 클립보드 기록 앱이 새 복사로 본다). 되돌리기는 0.8초 뒤. 앱이 느리거나(AX `.cannotComplete`) 글 칸이 아니면 되돌리지 않고 받아쓴 글을 남긴다.
- 보안 입력: `IsSecureEventInputEnabled()`는 시스템 전체라 한 앱이 켜 두면 모든 앱에 붙여넣기가 막힌다. `CGSessionCopyCurrentDictionary()`의 `kCGSSessionSecureInputPID`로 건 앱을 보고, 붙여 넣을 앱이 건 것이거나 모를 때만 클립보드에만 넣는다. 그때는 `.currentHostOnly` + Concealed로 넣는다 (다른 기기로 동기화되지 않게).
- 띄어쓰기: 손쉬운 사용으로 커서 앞 글자(`kAXSelectedTextRangeAttribute` + `kAXStringForRangeParameterizedAttribute`)를 읽어 정한다. 모르면(터미널 등) 같은 앱 · 30초 안 · 그사이 사용자가 키를 안 쳤을 때만 띄운다. 일본어 · 중국어는 띄우지 않는다. AX 호출에는 0.25초 제한(`AXUIElementSetMessagingTimeout`)을 걸고 메인 스레드 밖에서 한다.
- fn(지구본) 키의 동작은 `com.apple.HIToolbox`의 `AppleFnUsageType`: 0 안 함, 1 입력 소스 바꾸기, 2 이모지, 3 받아쓰기(macOS 받아쓰기는 두 번 누르기라 손 떼고 듣기와 겹친다). 한국어 macOS 26의 설정 이름은 "🌐︎ 키를 누를 때 실행할 동작" › "안 함".
- 화면 잠금 · `screensDidSleep` · `willSleep` · 사용자 전환이면 듣던 것을 버린다. 듣는 동안은 IOPM `PreventUserIdleDisplaySleep`을 잡아 손 떼고 듣는 중에 화면이 꺼져 버려지지 않게 한다.
- 노치: 소리 크기 · 중간 글은 `DictationLiveState`(귀 뷰만 지켜봄)로 보내서 초당 20번 바뀌어도 `NotchModel`은 바뀌지 않는다 (테스트로 확인). 받아쓰기 귀는 단계가 바뀔 때만 `NotchModel.dictation`을 바꾼다.
- 아직 실제로 못 본 것: 진짜 마이크 · 다른 앱에 붙여 넣기 전부, 크롬 · Electron에서 한글 조합 중 메뉴 붙여넣기 (조합이 남는지 · 겹치는지. 문제면 입력기가 조합 모드일 때는 ⌘V로), Safari 웹 페이지의 AX 선택 범위, 15.x의 `accessBehavior` 값, Apple 언어 모델 내려받기(`downloadAssets`), SpeechAnalyzer가 음성 인식 TCC를 묻는지.
