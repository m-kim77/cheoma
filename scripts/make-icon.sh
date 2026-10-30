#!/bin/sh
# 앱 아이콘 만들기: design/icon/AppIcon*.svg → Support/AppIcon.icns
#   scripts/make-icon.sh
# 필요한 것: rsvg-convert (brew install librsvg)
# 아이콘 디자인을 바꿀 때만 돌린다. 만든 AppIcon.icns는 저장소에 넣어 두므로 앱 빌드에는 필요 없다
set -e
cd "$(dirname "$0")/.."

SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
# 16·32px은 선을 굵게 그린 작은 크기용 그림을 쓴다
render() { rsvg-convert -w "$2" -h "$2" "design/icon/$1" -o "$SET/$3"; }
render AppIcon-small.svg 16   icon_16x16.png
render AppIcon-small.svg 32   icon_16x16@2x.png
render AppIcon-small.svg 32   icon_32x32.png
render AppIcon.svg       64   icon_32x32@2x.png
render AppIcon.svg       128  icon_128x128.png
render AppIcon.svg       256  icon_128x128@2x.png
render AppIcon.svg       256  icon_256x256.png
render AppIcon.svg       512  icon_256x256@2x.png
render AppIcon.svg       512  icon_512x512.png
render AppIcon.svg       1024 icon_512x512@2x.png
iconutil -c icns "$SET" -o Support/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "만들었어요: Support/AppIcon.icns"
