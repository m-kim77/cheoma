# 아이콘 시안 기록

2026-10-30에 앱 아이콘을 정하면서 만든 시안들. 고른 것은 **A · 끝 들림** (`../AppIcon.svg`, `../cheoma-mark.svg`).

- `vector-v1.png`: 처음 시안. 원래 마크(0), 끝 들림(A), 용마루(B), 채운 지붕(C). A·B는 끝이 너무 말려 물결처럼, C는 모자처럼 보였다
- `vector-v2.png`: 곡선을 다듬은 두 번째 시안. 여기서 A를 골랐다
- `vector-sheet.py`: 위 비교표를 그린 스크립트 (`python3 vector-sheet.py <출력.png>`, rsvg-convert·Pillow 필요)
- `pixel/`: Aseprite 픽셀 시안. 32×32 전각(용마루·기와·와구토·단청·기둥)과 18×10 메뉴바 마크
  - `make.lua`로 다시 그린다: `aseprite -b --script-param out=<폴더> --script make.lua`
  - 메뉴바 마크는 18px 안에서 끝 들림이 안 보여 `^`처럼 읽혔다
