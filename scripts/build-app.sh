#!/bin/sh
# Cheoma.app 만들기: 릴리스 빌드 → 앱 번들 구성 → 서명 (→ 공증)
#   scripts/build-app.sh            dist/Cheoma.app 생성
#   scripts/build-app.sh --install  ~/Applications/Cheoma.app 에도 복사
# 환경 변수
#   JOBS            빌드 동시 작업 수 (기본 2: 팬이 덜 돈다)
#   SIGN_IDENTITY   서명 인증서 이름. 예: "Developer ID Application: 이름 (TEAMID)". 없으면 ad-hoc 서명
#   NOTARY_PROFILE  공증에 쓸 notarytool 키체인 프로필 이름 (xcrun notarytool store-credentials로 만든다).
#                   있으면 Apple 공증을 받고 배포용 dist/Cheoma.zip을 만든다
set -e
cd "$(dirname "$0")/.."

JOBS="${JOBS:-2}"
IDENTITY="${SIGN_IDENTITY:--}"
nice -n 10 swift build -c release -j "$JOBS" --product Cheoma
nice -n 10 swift build -c release -j "$JOBS" --product CheomaFanHelper
BIN="$(swift build -c release --show-bin-path)"

APP="dist/Cheoma.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Cheoma" "$BIN/CheomaFanHelper" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/"

# 배포판과 같은 조건(hardened runtime)으로 서명해서 개발 중에도 같은 제약에서 돌려본다.
# 인증서로 서명할 때는 공증에 필요한 보안 타임스탬프도 넣는다
SIGN_FLAGS="--force --options runtime"
if [ "$IDENTITY" != "-" ]; then
    SIGN_FLAGS="$SIGN_FLAGS --timestamp"
fi
# 안쪽 실행 파일부터 서명한 뒤 번들 전체를 서명한다
codesign $SIGN_FLAGS --sign "$IDENTITY" "$APP/Contents/MacOS/CheomaFanHelper"
codesign $SIGN_FLAGS --sign "$IDENTITY" "$APP"
echo "만들었어요: $APP (서명: $IDENTITY)"

if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$IDENTITY" = "-" ]; then
        echo "공증하려면 SIGN_IDENTITY에 Developer ID 인증서가 필요해요" >&2
        exit 1
    fi
    ZIP="dist/Cheoma.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    # 공증 결과를 앱에 붙여서(인터넷 없이도 확인되게) 그 앱으로 다시 묶는다
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "배포용: $ZIP"
fi

if [ "$1" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Cheoma.app"
    ditto "$APP" "$HOME/Applications/Cheoma.app"
    echo "설치했어요: $HOME/Applications/Cheoma.app"
fi
