# 고칠 문제

2026-10-30 밤 점검(코드 리뷰, 빌드 경고, 실행 중인 앱 측정, 로그·크래시 확인)에서 나온 목록 가운데 아직 남은 것이다.
고치면 이 문서에서 지우고 [PROGRESS.md](PROGRESS.md) 작업 기록에 남긴다. 2026-10-31에 "꼭 고칠 것" 여섯 개와 "고치면 좋은 것"은 모두 고쳤다 (작업 기록 10/31).

전체 상태: 크래시 0건, 메모리 누수 없음. 대시보드를 닫았을 때 CPU 약 0.3%, 그래프 탭 1분 4.7%. debug·release 빌드 warning 0건, `-strict-concurrency=complete`도 0건. 단위 테스트 28개.

## 실제 기기에서 확인할 것

코드와 테스트로는 확인했지만, 사용 중인 맥을 건드려야 해서 직접 보지 못한 것.

- **팬 도우미 v4**: 새 빌드를 설치하고 팬 탭에서 도우미를 다시 설치한 뒤 고정 · 멈춤 · 온도별이 그대로 되는지. 잠자기 뒤 수동 설정이 유지되는지(로그에 "앱 응답 없음"이 없어야 한다). 다른 프로세스의 연결이 거부되는지는 `/var/log/io.github.m-kim77.cheoma.fanhelper.log`의 "연결 거부"로 본다.
- **설치 중 서명 확인**: root 셸의 복사 · `codesign -R` 확인 · plist 쓰기는 단위 테스트가 root 없이 돌려 봤다. 실제 설치(launchctl, `/Library`)는 암호를 넣어야 해서 아직이다.
- **가려진 아이콘**: 화면 밖으로 밀린 아이콘을 눌러 메뉴를 열고 닫으면 바로 다시 숨는지, 정리 모드에서 타일을 누르면 메뉴가 화면 안에 열리는지.
- **노치 없는 화면의 전체화면**: 외장 모니터만 쓸 때 전체화면 영상 위에 검은 알약이 안 보이는지 (메뉴바가 보이는 상태의 판정은 확인했다).

## 나중에 (선택)

- 대시보드를 열면 그래픽 메모리 약 190MB (닫으면 회수됨, 누수 아님). 10/31 `footprint`로 다시 재 보니 그래픽 187MB 중 128MB가 시스템이 필요하면 가져가는(reclaimable) 캐시였다. 큰 shadow나 Canvas 레이어 캐시로 보인다. 급하지 않다.
- 디스크·GPU 샘플러가 tick마다 IOKit 매칭을 새로 한다 (`IORegistry.forEach`, `GPUSampler`). 각각 0.03ms 안팎이라 급하지 않다. 바꾸려면 매칭 알림(`IOServiceAddMatchingNotification`)으로 서비스 목록을 기억해 둔다.
- `DashboardView`가 `StatsStore` 전체를 관찰한다. snapshot과 history가 매 tick 같이 바뀌어서 나눠도 다시 그리는 횟수는 거의 같다.
- 도우미 watchdog은 자동 모드에서도 2초마다 깨어난다 (leeway 0.5초를 줬다). 수동일 때만 돌리게 바꿀 수 있다.
- `--bench`는 릴리스 빌드에서도 동작한다. 성능은 릴리스 빌드로 재야 해서 일부러 둔다 (기록 파일은 이제 쓰지 않는다).

## 이미 고친 것 (`feature-toggles` `03d8743`, 아직 main에 안 합침)

- 노치를 열 때 직전 측정이 0.5초 안이면 즉시 측정 생략 (dt 수 ms 스파이크).
- 헤더 시계 `.everyMinute` (main에도 10/31에 같은 수정이 들어갔다).
- 1초 고정 타이머 제거: 열림 1초, 기록 2초, 팬 온도만 4초, 그 밖엔 멈춤 (닫혀 있을 때 헛 wakeup, 화면 꺼져도 계속 재던 문제).
- 기록이 바뀌었을 때만 저장.

## 코드 밖 (이 맥 환경)

- Macs Fan Control의 SMC 도우미(`com.crystalidea.macsfancontrol.smcwrite`)가 같이 돌고 있다. 같은 팬 키를 서로 덮어쓸 수 있으니 둘 중 하나만 쓴다.
- 옛 `com.notchbar.fanhelper`가 launchd에 아직 등록돼 있다 (`/Library/LaunchDaemons`, `/Library/PrivilegedHelperTools`). `sudo launchctl bootout system/com.notchbar.fanhelper` 후 파일 삭제.
- 작업 폴더의 `dist/`에 예전 `NotchBar.app`이 남아 있다 (git에는 안 올라간다).
