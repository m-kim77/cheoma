#!/bin/sh
# 단위 테스트: scripts/test.sh [swift test 옵션]
# XCTest는 Xcode에 들어 있다. 명령줄 도구만 선택돼 있으면(xcode-select) Xcode를 찾아 쓴다
set -e
cd "$(dirname "$0")/.."
if [ -z "$DEVELOPER_DIR" ] && xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
    XCODE="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -n 1)"
    XCODE="${XCODE:-/Applications/Xcode.app}"
    if [ -d "$XCODE/Contents/Developer" ]; then
        export DEVELOPER_DIR="$XCODE/Contents/Developer"
    else
        echo "XCTest가 필요해요. Xcode를 설치하세요." >&2
        exit 1
    fi
fi
nice -n 10 swift test -j "${JOBS:-2}" "$@"
