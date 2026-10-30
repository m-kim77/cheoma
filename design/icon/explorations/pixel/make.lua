-- 처마 픽셀 아이콘: 32×32 앱 아이콘과 18×10 메뉴바 마크
-- aseprite -b --script-param out=<폴더> --script make.lua
local out = app.params.out

local C = {
  ["."] = nil,
  w = Color{ r=244, g=241, b=232 },   -- 용마루·와구토 흰색
  g = Color{ r=88,  g=106, b=128 },   -- 기와 회청색
  G = Color{ r=52,  g=66,  b=88  },   -- 기와 어두운 쪽
  h = Color{ r=128, g=146, b=166 },   -- 기와 밝은 쪽
  d = Color{ r=58,  g=150, b=124 },   -- 단청 초록
  b = Color{ r=72,  g=110, b=190 },   -- 단청 파랑
  r = Color{ r=178, g=56,  b=46  },   -- 기둥 빨강
  y = Color{ r=255, g=197, b=107 },   -- 처마 밑 불빛
  s = Color{ r=20,  g=22,  b=40  },   -- 처마 밑 그늘
  k = Color{ r=0,   g=0,   b=0   },   -- 메뉴바 마크 (템플릿 이미지)
}

-- 왼쪽 절반만 그리고 좌우로 뒤집어 붙인다
local function mirror(half)
  local rows = {}
  for i, row in ipairs(half) do
    rows[i] = row .. row:reverse()
  end
  return rows
end

local function stamp(img, rows, ox, oy)
  for y, row in ipairs(rows) do
    for x = 1, #row do
      local c = C[row:sub(x, x)]
      if c then img:drawPixel(ox + x - 1, oy + y - 1, c) end
    end
  end
end

-- 둥근 네모 판 + 밤하늘 그라데이션 (가로 띠)
local bands = {
  { 0,  Color{ r=21,  g=29,  b=61  } },
  { 12, Color{ r=38,  g=40,  b=90  } },
  { 19, Color{ r=72,  g=56,  b=118 } },
  { 23, Color{ r=150, g=96,  b=140 } },
}
local function bandColor(x, y)
  local c = bands[1][2]
  for _, band in ipairs(bands) do
    if y >= band[1] then c = band[2] end
  end
  return c
end

local function plate(img, x0, y0, size, radius)
  for y = y0, y0 + size - 1 do
    for x = x0, x0 + size - 1 do
      local dx = math.max(x0 + radius - x - 0.5, 0, x - (x0 + size - 1 - radius) + 0.5)
      local dy = math.max(y0 + radius - y - 0.5, 0, y - (y0 + size - 1 - radius) + 0.5)
      if dx * dx + dy * dy <= radius * radius then
        img:drawPixel(x, y, bandColor(x - x0, y - y0))
      end
    end
  end
end

-- 팔작지붕 정면: 용마루, 기와, 와구토, 단청, 기둥 (가로 24칸)
local building = mirror({
  "......w.....",
  "......wwwwww",
  "......Ghhhhh",
  "......Ghhhhh",
  ".....GGggggg",
  "....GGgggggg",
  "w.GGGggggggg",
  "wGGggggggggg",
  ".wGwGwGwGwGw",
  "..dbddbddbdd",
  "...sssssssss",
  "....rsyyrsyy",
  "....rsyyrsyy",
  "....rsyyrsyy",
  "...wwwwwwwww",
})

local icon = Sprite(32, 32, ColorMode.RGB)
icon.filename = out .. "/cheoma-icon.aseprite"
local img = icon.cels[1].image
app.transaction(function()
  plate(img, 3, 3, 26, 6)
  -- 별
  for _, p in ipairs({ {8, 6}, {22, 5}, {25, 9}, {6, 11} }) do
    img:drawPixel(p[1], p[2], C.w)
  end
  img:drawPixel(18, 4, C.y)
  stamp(img, building, 4, 9)
end)
icon:saveAs(out .. "/cheoma-icon.aseprite")
icon:saveCopyAs(out .. "/cheoma-icon-32.png")

-- 메뉴바 마크: 끝이 들린 지붕선 (18×10, 1x 기준)
local mark = Sprite(18, 10, ColorMode.RGB)
stamp(mark.cels[1].image, mirror({
  "........k",
  ".......kk",
  "......kk.",
  ".....kk..",
  "....kk...",
  "k..kk....",
  "kkkk.....",
  ".kk......",
}), 0, 1)
mark:saveAs(out .. "/cheoma-menubar.aseprite")
mark:saveCopyAs(out .. "/cheoma-menubar-18.png")
