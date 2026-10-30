# 처마 로고 시안 비교표: 마크 4종 × (메뉴바 밝음/어두움, Dock 작게, 앱 아이콘)
import math, subprocess, io, sys
from PIL import Image, ImageDraw, ImageFont

OUT = sys.argv[1]

# 마크는 100×64 상자 안에 그린다
STROKE = 'fill="none" stroke="{c}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"'
MARKS = {
    "0 · 지금": ("stroke", 10.9,
        "M6.8 54.5 Q25 54.5 36.4 38.6 L50 18.2 L63.6 38.6 Q75 54.5 93.2 54.5"),
    "A · 끝 들림": ("stroke", 10,
        "M4 43 C16 55 44 32 50 15 C56 32 84 55 96 43"),
    "B · 용마루 + 끝 들림": ("stroke", 10,
        "M4 42 C16 54 37 34 42 18 L58 18 C63 34 84 54 96 42"),
    "C · 채운 지붕": ("fill", 0,
        "M33 8 Q35 11.5 38.5 11.5 H61.5 Q65 11.5 67 8 V14.5 H33 Z "
        "M37 17.5 H63 C68 32 80 42 98 33 C82 46 64 48.5 50 48.5 C36 48.5 18 46 2 33 C20 42 32 32 37 17.5 Z"),
}

def mark_svg(kind, w, d, color, tx=0, ty=0, s=1):
    if kind == "stroke":
        el = f'<path d="{d}" ' + STROKE.format(c=color, w=w) + '/>'
    else:
        el = f'<path d="{d}" fill="{color}"/>'
    return f'<g transform="translate({tx} {ty}) scale({s})">{el}</g>'

def squircle(x, y, size, n=5.0, steps=256):
    r = size / 2; cx = x + r; cy = y + r
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s_ = math.cos(t), math.sin(t)
        px = cx + r * math.copysign(abs(c) ** (2 / n), c)
        py = cy + r * math.copysign(abs(s_) ** (2 / n), s_)
        pts.append(f"{px:.2f} {py:.2f}")
    return "M" + " L".join(pts) + " Z"

def icon_svg(kind, w, d):
    # 애플 아이콘 격자: 1024 캔버스, 824 판
    plate = squircle(100, 100, 824)
    s = 5.6                       # 마크 폭 560
    tx = 512 - 50 * s; ty = 512 - 34 * s
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
 <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#151d3d"/><stop offset="0.5" stop-color="#2c2d60"/><stop offset="0.82" stop-color="#7a5384"/><stop offset="1" stop-color="#c98490"/>
 </linearGradient>
 <filter id="blur"><feGaussianBlur stdDeviation="38"/></filter>
 <filter id="sh" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-opacity="0.35"/></filter>
 <clipPath id="clip"><path d="{plate}"/></clipPath>
</defs>
<path d="{plate}" fill="url(#bg)" filter="url(#sh)"/>
<g clip-path="url(#clip)"><ellipse cx="512" cy="{ty + 50 * s}" rx="250" ry="46" fill="#ffc56b" opacity="0.32" filter="url(#blur)"/></g>
{mark_svg(kind, w, d, "#ffffff", tx, ty, s)}
</svg>'''

def menubar_svg(kind, w, d, dark, scale):
    # 메뉴바 높이 24pt, 마크 높이 약 14pt (@2x면 2배)
    H = 24 * scale; W = 44 * scale
    bg = "#2b2b30" if dark else "#e9e9ee"
    fg = "#ffffff" if dark else "#1d1d1f"
    s = 20 * scale / 100          # 마크 폭 20pt
    tx = W / 2 - 50 * s; ty = H / 2 - 34 * s
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<rect width="{W}" height="{H}" fill="{bg}"/>{mark_svg(kind, w, d, fg, tx, ty, s)}</svg>'''

def render(svg, width=None):
    args = ["rsvg-convert", "-f", "png"]
    if width: args += ["-w", str(width)]
    png = subprocess.run(args, input=svg.encode(), capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")

font = ImageFont.truetype("/System/Library/Fonts/AppleSDGothicNeo.ttc", 26)
small = ImageFont.truetype("/System/Library/Fonts/AppleSDGothicNeo.ttc", 20)
cols = [("메뉴바 1x (실제 크기)", 260), ("메뉴바 2x", 260), ("메뉴바 2x 다크", 260), ("Dock 64px", 170), ("앱 아이콘 360px", 420)]
rowh = 400
sheet = Image.new("RGBA", (sum(c[1] for c in cols) + 280, 70 + rowh * len(MARKS)), "#f5f5f7")
dr = ImageDraw.Draw(sheet)
x = 280
for title, cw in cols:
    dr.text((x, 22), title, fill="#555", font=small); x += cw
for r, (name, (kind, w, d)) in enumerate(MARKS.items()):
    y0 = 70 + r * rowh
    dr.text((24, y0 + rowh // 2 - 16), name, fill="#111", font=font)
    x = 280
    for i, (title, cw) in enumerate(cols):
        if i == 0: im = render(menubar_svg(kind, w, d, False, 1))
        elif i == 1: im = render(menubar_svg(kind, w, d, False, 2))
        elif i == 2: im = render(menubar_svg(kind, w, d, True, 2))
        elif i == 3: im = render(icon_svg(kind, w, d), 64)
        else: im = render(icon_svg(kind, w, d), 360)
        sheet.alpha_composite(im, (x, y0 + (rowh - im.height) // 2))
        x += cw
sheet.convert("RGB").save(OUT)
print(OUT)
