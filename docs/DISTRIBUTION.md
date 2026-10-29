# 배포 계획

다른 사람이 내려받아 쓰게 하려면 무엇이 필요한지, 지금 어디까지 준비됐는지 정리한다.

## 방향 (2026-10-29)

- 포트폴리오 겸 **무료 배포**. 코드는 GitHub 공개 저장소에 올린다.
- **추가 비용 없이** 한다. Apple Developer Program(연 99달러)은 나중에 필요해지면 가입한다. 그 전까지는 아래 "무료로 배포하기"대로 간다.
- 이름은 **Cheoma(처마)**. 처음 이름인 NotchBar는 이미 다른 프로젝트 여럿이 쓰고 있어서 바꿨다 (navtoj/NotchBar, azu/notchbar 등). 번들 ID는 `io.github.m-kim77.cheoma`.
- 라이선스는 GPL-3.0. 저장소는 `github.com/m-kim77/cheoma`이고, 첫 릴리스 전까지는 비공개로 둔다.
- Homebrew는 나중에 한다.

## 무료로 배포하기

드는 돈이 없는 것만 쓴다.

| 할 일 | 쓰는 것 | 비용 |
|---|---|---|
| 코드 공개 | GitHub 공개 저장소 | 무료 |
| 앱 내려받기 | GitHub Releases에 zip 올리기 | 무료 |
| 자동 빌드 (선택) | GitHub Actions (공개 저장소는 macOS 빌드도 무료) | 무료 |
| 소개 페이지 (선택) | README, 또는 GitHub Pages(`아이디.github.io`) | 무료 |
| 서명 | ad-hoc 서명 (지금과 같음) | 무료 |

Developer ID가 없어서 생기는 일과 대응:

- **처음 열 때 macOS가 막는다.** 인터넷에서 받은 서명 안 된 앱이라서다. macOS 15부터는 우클릭 › 열기로 넘어갈 수 없고, 시스템 설정 › 개인정보 보호 및 보안 › 맨 아래 "그래도 열기"를 눌러야 한다. README 설치 방법에 그림과 함께 적는다. 터미널을 쓰는 사람은 `xattr -dr com.apple.quarantine /Applications/<앱>.app`으로도 된다.
- **업데이트할 때마다 손쉬운 사용 권한을 다시 줘야 한다.** ad-hoc 서명은 빌드마다 서명이 달라져서 macOS가 다른 앱으로 본다. 시스템 설정에는 켜져 있는데 동작하지 않는 상태가 되므로, 앱이 이걸 알아채고 "목록에서 지우고 다시 허용" 방법을 안내해야 한다.
  - 무료로 피하는 방법은 자체 서명 인증서 하나로 매번 서명하는 것이다. 그러면 업데이트해도 권한이 유지된다 (처음 열 때 막히는 건 같다). 2026-10-29 개발용으로는 쓰지 않기로 했다. 배포용으로 쓸지는 아직 정하지 않았다.
- **팬 도우미**: 지금 방식(관리자 암호로 설치)은 서명 없이도 된다. SMAppService 방식은 Developer ID가 있어야 해서, 가입 전까지는 지금 방식을 유지한다.
- **Homebrew**: 공식 저장소(homebrew/cask)는 서명·공증 안 된 앱을 받지 않는다. 내 tap(`아이디/homebrew-tap`)은 무료로 만들 수 있다.

## Developer ID로 바꾸면 (나중에)

Apple Developer Program(연 99달러)에 가입해서 **Developer ID**로 서명하고 Apple **공증**을 받으면, 처음 열 때 막히지 않고 업데이트해도 권한이 유지된다. 방법은 아래 "직접 해야 하는 것"에 있다.

## 업데이트하면 권한을 다시 줘야 하나

macOS는 손쉬운 사용 권한을 줄 때 앱의 서명 정보도 같이 기억한다. 그래서 어떻게 서명하느냐에 따라 달라진다.

| 서명 | 다른 맥에서 처음 열 때 | 업데이트 후 권한 |
|---|---|---|
| ad-hoc (지금) | 막힌다. 시스템 설정 › 개인정보 보호 및 보안 › "그래도 열기"를 눌러야 한다 | 매번 다시 줘야 한다 |
| 자체 서명 인증서 | 막힌다 (위와 같음) | 같은 인증서로 서명하면 유지된다 |
| Developer ID + 공증 | 바로 열린다 | 같은 팀으로 서명하면 유지된다 |

Developer ID로 서명한 앱은 macOS가 "팀 ID + 번들 ID(`io.github.m-kim77.cheoma`)"로 알아본다. 같은 팀으로 서명한 새 버전은 같은 앱으로 취급하므로 권한이 그대로 남는다.

## App Store는 안 된다

App Store 앱은 샌드박스 안에서만 돌아야 하는데, Cheoma의 핵심 기능은 모두 샌드박스 밖에서만 된다. SMC(온도·팬), IOReport(구성요소별 전력), 다른 앱의 메뉴바 아이콘 누르기(손쉬운 사용), 관리자 권한 팬 도우미가 그렇다. 그래서 웹사이트나 GitHub에서 직접 배포한다.

## 지금 준비된 것

- `scripts/build-app.sh`에 `SIGN_IDENTITY`(Developer ID 인증서 이름)를 주면 그 인증서로 서명한다. `NOTARY_PROFILE`까지 주면 Apple 공증을 받고 배포용 `dist/Cheoma.zip`을 만든다.
- 개발 빌드도 배포판과 같은 hardened runtime으로 서명한다. 이 조건에서 센서(SMC, IOReport)가 동작하는 것을 확인했다 (2026-10-29). 손쉬운 사용과 팬 도우미는 권한을 다시 받은 뒤 확인한다.
- 팬 도우미는 설치할 때 버전을 적어 둔다. 업데이트로 도우미가 바뀌면 앱이 "다시 설치"를 안내한다.

## 직접 해야 하는 것 (Developer ID로 바꿀 때)

1. Apple Developer Program 가입: https://developer.apple.com/programs/ (연 99달러)
2. Developer ID Application 인증서 만들기: Xcode › Settings › Accounts › 팀 선택 › Manage Certificates › `+` › Developer ID Application
3. 공증용 프로필 저장 (한 번만). 암호는 appleid.apple.com에서 만든 앱 암호를 넣는다.
   ```sh
   xcrun notarytool store-credentials cheoma --apple-id <Apple ID 이메일> --team-id <TEAMID>
   ```
4. 배포 빌드
   ```sh
   SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" NOTARY_PROFILE=cheoma scripts/build-app.sh
   ```

무료 Apple ID로 받는 "Apple Development" 인증서는 내 맥에서 개발할 때만 쓸 수 있고, 다른 사람에게 배포하는 용도로는 쓸 수 없다.

## 맥 종류별로 되는 것

| 맥 | 시스템 모니터 | 팬 조절 | 노치 |
|---|---|---|---|
| MacBook Pro (M 시리즈) | 됨 | 됨 (M5 Max에서 확인) | 실제 노치 |
| MacBook Air | 됨 | 팬이 없어서 없음 (팬 탭이 안 나온다) | 실제 노치 (M2 이후) |
| Mac Studio · Mac mini · iMac | 됨 | 팬이 있어서 될 것으로 보지만 아직 시험 못 함 | 노치가 없어서 화면 위 가운데에 가상 노치 |

- 팬 조절은 SMC 키(`F0md`/`F0Md`, `F0Tg`)로 한다. M1·M2는 수동 제어 전에 다른 키(`Ftst`)가 필요할 수 있어서 실제 기기에서 시험해야 한다. 안 되면 앱이 8초 안에 알아채고 자동으로 되돌린다.
- 인텔 맥은 대상이 아니다 (Apple Silicon 전용 빌드, 전력 측정 방식이 다름).

## 배포 전에 개발할 것

무료 배포에 필요한 것:

- 스크린샷 (`--render`로 만든다)
- 앱 아이콘 (디자인 시안을 고른 뒤)
- 처음 실행 안내: 손쉬운 사용 권한이 왜 필요한지 설명하는 화면
- 권한이 풀렸을 때 안내: 업데이트 뒤 시스템 설정에는 켜져 있는데 동작하지 않는 경우를 알아채고 다시 허용하는 방법을 보여준다
- 업데이트 확인: GitHub Releases의 최신 버전과 비교해서 새 버전이 있으면 알려준다
- 릴리스 스크립트: 버전 올리기 → 빌드 → zip → sha256 출력

Developer ID를 쓰게 되면:

- 팬 도우미 설치를 SMAppService(macOS 13+) 방식으로 바꾸기. 관리자 셸 스크립트 대신 앱 안에 든 도우미를 등록하고, 사용자는 시스템 설정 › 일반 › 로그인 항목에서 허용한다. Apple이 권하는 방식이고 Developer ID 서명이 있어야 한다.
- 팬 도우미가 연결한 앱을 경로가 아니라 서명(팀 ID)으로 확인하기. 사용자가 앱을 어디에 두든 동작하고 더 안전하다.

공통:

- 다른 맥에서 테스트: 팬이 없는 MacBook Air, M1·M2(팬 제어 방식이 다를 수 있음), 노치 없는 맥, 외장 모니터
- 버전 번호: 배포할 때마다 `Support/Info.plist`의 `CFBundleShortVersionString`과 `CFBundleVersion`을 올린다
