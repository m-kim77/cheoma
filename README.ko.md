# Cheoma (처마)

[English](README.md) · 한국어

**처마**는 한옥 지붕 끝에 길게 나온 부분이다. 비와 햇빛을 가려 주고, 그 밑에는 곶감이나 메주처럼 자주 쓰는 것을 걸어 둔다. 처마 끝 풍경은 바람이 불면 소리로 알려 준다.

Cheoma는 맥의 노치에서 같은 일을 한다. 어수선한 메뉴바 아이콘은 노치 뒤로 가려 두었다가 필요할 때 노치 아래로 꺼내 쓰고, 무슨 일이 생기면 노치에 알림을 띄운다. 노치에 마우스를 올리면 CPU·GPU·전력·온도가 한눈에 보이고, 팬을 조절해 맥을 시원하게 지킨다.

macOS 14 이상, Apple Silicon 맥용 무료 앱이다.

- **노치 알림**: 충전기 연결/해제, 잠금 해제, `--notify`로 보낸 알림이 노치 양옆에 잠깐 떴다 사라진다 (소리 없음)
- **경고 알림**: 과열, 메모리 부족, 배터리 20%·10%일 때 노치로 알린다. 같은 종류는 10분에 한 번만 (`⌄` 우클릭 › 경고 알림으로 끄기)
- **노치 대시보드**: 노치에 마우스를 올리면 펼쳐진다
  - 모양: 대시보드 오른쪽 위 기둥 모양 버튼을 누르거나 `⌄` 우클릭 › 노치 모양에서 **기본**(둥근 네모)과 **광화문**(2층 지붕 아래 석축에 대시보드가 들어가는 검은 실루엣)을 바꾼다
  - 개요: CPU(코어별) · GPU · 메모리 · 전력 · 네트워크 · 저장장치
  - 그래프: CPU · GPU · 전력 · 네트워크를 1분 / 10분 / 1시간 / 24시간으로 (기록은 앱을 다시 켜도 유지)
  - 전력: 시스템 전체 · CPU · GPU · 뉴럴 엔진 · 메모리 · 디스플레이 · 기타, 배터리 상태
  - 온도: CPU · GPU · SSD · 배터리 온도와 팬 RPM, CPU·GPU 온도 10분 그래프
  - 팬: 자동 / 고정(팬별 RPM, 저장, 멈춤) / 온도별(온도-RPM 커브)
  - 앱: CPU · CPU 전력 · 메모리를 많이 쓰는 앱 (도우미 프로세스는 앱 하나로 합침)
- **가려진 메뉴바 아이콘**: 메뉴바의 `⌄`를 누르면 노치 뒤에 가려진 아이콘이 아래로 펼쳐지고, 눌러서 바로 쓸 수 있다

진행 상황과 남은 일은 [docs/PROGRESS.md](docs/PROGRESS.md), 기술 메모는 [docs/NOTES.md](docs/NOTES.md), 배포 계획은 [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)에 있다.

## 설치

1. [Releases](https://github.com/m-kim77/cheoma/releases)에서 `Cheoma.zip`을 받아 풀고, `Cheoma.app`을 응용 프로그램 폴더로 옮긴다.
2. 처음 열면 macOS가 "확인되지 않은 개발자"라며 막는다. Apple 유료 개발자 인증서로 서명하지 않은 무료 앱이라서 그렇다. 시스템 설정 › 개인정보 보호 및 보안 › 맨 아래 **"그래도 열기"**를 누른다. 터미널에서는 `xattr -dr com.apple.quarantine /Applications/Cheoma.app`로도 된다.
3. 메뉴바의 `⌄`를 눌러 손쉬운 사용 권한을 허용한다 (가려진 아이콘을 누르는 데 필요하다).

업데이트한 뒤 가려진 아이콘이 안 눌리면 손쉬운 사용 목록에서 Cheoma를 `−`로 지우고 다시 허용한다.

## 빌드 / 실행

```sh
scripts/build-app.sh --install   # 릴리스 빌드 → ~/Applications/Cheoma.app 설치
open ~/Applications/Cheoma.app
```

개발 중에는 `swift build && .build/debug/Cheoma`로 바로 실행해도 된다.
빌드 스크립트는 팬이 덜 돌도록 기본으로 동시 작업 2개(`JOBS=2`)만 쓴다.
배포판과 같은 조건이 되도록 hardened runtime으로 서명한다. `SIGN_IDENTITY`(Developer ID 인증서)와 `NOTARY_PROFILE`(공증 프로필)을 주면 배포용으로 서명·공증한다 ([배포 계획](docs/DISTRIBUTION.md)).

## 권한

| 기능 | 필요한 것 |
|---|---|
| 가려진 아이콘 읽기 · 누르기 | 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용 (패널의 "권한 허용하러 가기") |
| 팬 속도 조절 | 관리자 권한 도우미 설치 (온도 탭의 "도우미 설치", 관리자 암호 필요) |
| 로그인 시 자동 실행 | 메뉴바 `⌄` 우클릭 › 로그인 시 자동 실행 (.app으로 실행할 때만) |

지금은 ad-hoc 서명이라 앱을 다시 빌드하면 손쉬운 사용 권한을 다시 허용해야 한다. 시스템 설정에 Cheoma가 켜져 있는데도 안 되면 예전 빌드에 준 권한이므로 `tccutil reset Accessibility io.github.m-kim77.cheoma`으로 지우고 다시 허용한다. Developer ID로 서명하면 업데이트해도 권한이 유지된다.

## 가려진 아이콘

- macOS가 자리가 없어 노치 뒤에 숨긴 아이콘은 자동으로 찾는다. 따로 설정할 것은 없다.
- 일부러 숨기고 싶은 아이콘은 패널의 **정리** → 메뉴바에서 ⌘ 누른 채 `|` 왼쪽으로 끌기 → **완료**.
- 아이콘은 손쉬운 사용 API로 누른다. 앱이 마우스를 움직이거나 아이콘을 대신 옮기지는 않는다.
- 패널에서 아이콘을 우클릭하면 열기 · Finder에서 보기 · 앱 종료 메뉴가 나온다. 앱 자체의 우클릭 메뉴는 macOS가 손쉬운 사용으로 열 수 있게 해 주지 않아서 띄울 수 없다.
- macOS 26은 메뉴바가 넘칠 때(새 아이콘이 생기는 등) 아이콘 순서를 스스로 섞기도 한다.

## 팬 조절

팬 탭에서 고른다. 고른 모드와 값은 기억했다가 앱을 다시 켜면 이어서 적용한다. 왼쪽에는 팬마다 지금 RPM과 목표(흰 눈금)가 보인다.

- **자동**: macOS가 조절한다 (기본). 시원할 때는 팬이 멈춰 있다
- **고정**: 슬라이더로 RPM을 정한다. 끄는 동안에도 0.2초마다 적용돼서 팬이 바로 따라온다
  - "좌우 같이"를 끄면 팬 1·팬 2를 따로 정한다 (이 맥: 팬 1 1350~5349, 팬 2 1350~5777 RPM)
  - 자주 쓰는 속도는 "지금 속도 저장"으로 4개까지 저장해 두고 눌러서 바로 쓴다
  - "멈춤"은 팬을 세운다. 이 맥이 받아들이지 않으면 자동으로 되돌린다. 멈춘 동안은 CPU 85°C에서 자동으로 돌아간다
- **온도별**: 30·40·…·100°C 여덟 점의 RPM을 그래프에서 위아래로 끌어서 정한다
  - 곡선: 점 사이를 이어서 온도에 따라 자연스럽게 바뀐다. 높은 온도 쪽 점을 더 가파르게 두면 뜨거워질수록 빨리 올라간다 (기본값이 이 모양)
  - 계단: 다음 점의 온도에 닿을 때까지 그대로 있다가 한 번에 바뀐다
  - 커브는 뜨거운 쪽으로 갈수록 내려가지 않는다. 점을 올리면 더 뜨거운 쪽 점들이 같이 올라가고, 내리면 더 시원한 쪽 점들이 같이 내려간다 (끌다가 되돌리면 원래대로)
  - 아래 회색 띠(팬 최소보다 낮은 곳)에 둔 구간은 macOS 자동
  - 기준 온도는 CPU·GPU 평균 중 높은 값이고, 식을 때는 3°C 더 내려가야 속도를 낮춘다 (경계에서 팬이 오르내리지 않게)
- 팬이 8초 안에 설정한 속도를 따라오지 않으면 자동으로 되돌리고 알려준다
- 수동 설정은 앱이 켜져 있는 동안만 유지된다. 앱을 끄면 도우미가 자동으로 되돌린다
- 팬이 없는 맥(MacBook Air)에는 팬 탭이 나오지 않는다

## 팬 속도 도우미

`CheomaFanHelper`는 launchd가 root로 띄우는 작은 데몬이다. 할 수 있는 일은 팬 속도를 각 팬의 최소~최대 범위 안에서 정하거나 자동으로 되돌리는 것뿐이다.

- CPU 95°C 초과(팬을 멈춘 동안은 85°C), 앱 연결 끊김, 앱 응답 20초 없음 → 자동으로 되돌린다
- 설치 위치: `/Library/PrivilegedHelperTools/io.github.m-kim77.cheoma.fanhelper`, `/Library/LaunchDaemons/io.github.m-kim77.cheoma.fanhelper.plist`
- 설치한 앱 실행 파일에서 온 연결만 받는다. 앱 위치가 바뀌거나 업데이트로 도우미가 바뀌면 온도 탭에 "다시 설치"가 뜬다.
- 로그: `/var/log/io.github.m-kim77.cheoma.fanhelper.log`
- 제거: 온도 탭의 "도우미 제거", 또는
  ```sh
  sudo launchctl bootout system/io.github.m-kim77.cheoma.fanhelper
  sudo rm /Library/LaunchDaemons/io.github.m-kim77.cheoma.fanhelper.plist /Library/PrivilegedHelperTools/io.github.m-kim77.cheoma.fanhelper
  ```

## 노치 알림 보내기

```sh
~/Applications/Cheoma.app/Contents/MacOS/Cheoma --notify "빌드 완료" --symbol hammer.fill --color green
```

`--symbol`은 SF Symbol 이름, `--color`는 green · red · orange · yellow · blue · purple · pink · cyan · teal · white · gray.

오래 걸리는 작업이 끝날 때 띄우려면 명령 뒤에 붙인다:

```sh
make && ~/Applications/Cheoma.app/Contents/MacOS/Cheoma --notify "빌드 성공" --symbol checkmark.circle.fill --color green \
     || ~/Applications/Cheoma.app/Contents/MacOS/Cheoma --notify "빌드 실패" --symbol xmark.circle.fill --color red
```

## 개발용 옵션

| 옵션 | 내용 |
|---|---|
| `--stats` | UI 없이 3초간 센서 값 출력 |
| `--menubar-items` | 메뉴바 아이콘 목록과 가려짐 여부 출력 |
| `--render <폴더>` | 노치 UI를 PNG로 저장 (디버그 빌드, 화면 기록 권한 불필요) |
| `--bench [초] [탭]` | 센서 한 번 읽는 시간과 상황·탭별 CPU 사용률 측정 (대시보드는 1% 불투명도로 띄움, 팬은 안 건드림) |

## 데이터 위치

- 설정: `defaults read io.github.m-kim77.cheoma`
- 그래프 기록: `~/Library/Application Support/Cheoma/history.plist`
- 오류 로그: `~/Library/Logs/Cheoma.log`

## 알아둘 것

- CPU/GPU 구성요소별 전력(IOReport)과 실시간 전력·온도·팬(SMC)은 Apple이 공개하지 않은 인터페이스라, macOS 업데이트로 막히면 해당 값만 "—"로 표시된다.
- 다른 앱·게임의 FPS는 공개 API로 읽을 수 없어 화면 최대 주사율만 표시한다.
- CPU 사용량: 대시보드가 닫혀 있으면 약 0.2%, 어느 탭을 열어 둬도 약 1%다 (`--bench`로 측정). 닫혀 있으면 2초마다(온도·구성요소별 전력은 4초), 열려 있으면 1초마다(온도·구성요소별 전력은 2초) 잰다.
- 앱 탭은 내 계정 프로세스만 보여준다. WindowServer, kernel_task 같은 시스템 프로세스는 읽을 권한이 없다. "CPU 전력"은 CPU 몫 추정치라 GPU 사용분은 들어가지 않는다.

## 구조

```
Sources/
├── Cheoma/              앱
│   ├── Notch/           노치 창, 모양, 대시보드(개요·그래프·전력·온도·팬·앱)
│   ├── MenuBar/         메뉴바 아이콘(⌄, |), 가려진 아이콘 패널
│   ├── Stats/           센서 측정(CPU·GPU·메모리·네트워크·디스크·전력·온도·앱별 사용량), 기록
│   ├── Fans/            팬 도우미 연결·설치
│   ├── Events/          충전기·잠금 해제 감지, 경고 알림(과열·메모리·배터리)
│   └── Debug/           --render 미리보기
├── CheomaShared/        SMC 접근, 팬 도우미 XPC 규약 (앱과 도우미가 같이 씀)
└── CheomaFanHelper/     관리자 권한 팬 도우미
```

## 라이선스

[GPL-3.0](LICENSE). 고쳐서 다시 배포할 때는 고친 소스도 같은 라이선스로 공개해야 한다. "Cheoma"라는 이름과 아이콘은 이 프로젝트를 가리키는 데만 쓴다.
