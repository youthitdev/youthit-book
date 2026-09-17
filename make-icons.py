#!/usr/bin/env python3
"""한끗독서 아이콘 생성기.  python3 make-icons.py

SVG 를 손으로 고치면 PNG 가 따로 놀기 때문에, 한 곳에서 같이 만든다.
바깥 라이브러리 없이 순수 파이썬으로 그린다 (맥에 SVG 래스터라이저가 없어서).
모양이 셋뿐이라 직접 그리는 편이 도구를 까는 것보다 빠르다.
  · 둥근 사각형   — 모서리 원과의 거리
  · 책 두 쪽      — 3차 베지어를 잘게 쪼개 다각형으로, 짝수-홀수 규칙
  · 유스보이스 광선 — 선분과의 거리 (둥근 끝)
"""
import struct, zlib, math

W = 192
SS = 4                      # 픽셀당 4×4 초과표본
RX = 44                     # 둥근 모서리
BOOK_L = "M96 62 C82 52, 60 50, 44 54 L44 134 C60 130, 82 132, 96 142 Z"
BOOK_R = "M96 62 C110 52, 132 50, 148 54 L148 134 C132 130, 110 132, 96 142 Z"

THEMES = {
    'book':  ((0x3A, 0x40, 0xD6), (0x2A, 0x2F, 0xA8)),
    'admin': ((0xFF, 0x3D, 0x7F), (0xE0, 0x00, 0x5C)),
}
GOLD = (0xFF, 0xD6, 0x00)

# ── 경로 ────────────────────────────────────────────────
def flatten(d, steps=24):
    """아주 단순한 파서. 이 파일의 두 경로만 다룬다 (M C L C Z)"""
    import re
    toks = re.findall(r'[MCLZ]|-?\d+\.?\d*', d)
    pts, i, cur = [], 0, (0.0, 0.0)
    while i < len(toks):
        t = toks[i]; i += 1
        if t == 'M':
            cur = (float(toks[i]), float(toks[i+1])); i += 2; pts.append(cur)
        elif t == 'L':
            cur = (float(toks[i]), float(toks[i+1])); i += 2; pts.append(cur)
        elif t == 'C':
            p1 = (float(toks[i]),   float(toks[i+1]))
            p2 = (float(toks[i+2]), float(toks[i+3]))
            p3 = (float(toks[i+4]), float(toks[i+5])); i += 6
            for s in range(1, steps + 1):
                u = s / steps; v = 1 - u
                x = v*v*v*cur[0] + 3*v*v*u*p1[0] + 3*v*u*u*p2[0] + u*u*u*p3[0]
                y = v*v*v*cur[1] + 3*v*v*u*p1[1] + 3*v*u*u*p2[1] + u*u*u*p3[1]
                pts.append((x, y))
            cur = p3
        elif t == 'Z':
            pass
    return pts

def inside(poly, x, y):
    n, r = len(poly), False
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]; xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            r = not r
        j = i
    return r

def rrect(x, y, w, rx):
    cx = rx if x < rx else (w - rx if x > w - rx else x)
    cy = rx if y < rx else (w - rx if y > w - rx else y)
    return (x - cx) ** 2 + (y - cy) ** 2 <= rx * rx

def seg_dist(px, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    t = 0.0 if (dx == 0 and dy == 0) else max(0.0, min(1.0,
        ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (x1 + t * dx), py - (y1 + t * dy))

def spark_segments(cx, cy, R, inner_ratio=0.36):
    """유스보이스 마크 — 가운데가 빈 6갈래. 세로 2 + 대각선 4"""
    inner = R * inner_ratio
    out = []
    for a in (-90, 90, -150, -30, 150, 30):
        r = math.radians(a)
        out.append((cx + math.cos(r) * inner, cy + math.sin(r) * inner,
                    cx + math.cos(r) * R,     cy + math.sin(r) * R))
    return out

# ── 그리기 ──────────────────────────────────────────────
def render(theme='book', maskable=False, spark_w=9.0, spark_r=22.0):
    c0, c1 = THEMES[theme]
    L, R = flatten(BOOK_L), flatten(BOOK_R)
    segs = spark_segments(142, 46, spark_r)
    half = spark_w / 2

    def content(x, y):
        """책·광선만. (색, 알파) 를 돌려준다. 없으면 None"""
        for x1, y1, x2, y2 in segs:
            if seg_dist(x, y, x1, y1, x2, y2) <= half:
                return GOLD, 1.0
        if inside(L, x, y): return (255, 255, 255), 1.0
        if inside(R, x, y): return (255, 255, 255), 0.82
        return None

    # maskable 은 모서리를 깎지 않고 꽉 채우되 내용을 안전영역으로 줄인다
    scale, off = (0.72, 26.88) if maskable else (1.0, 0.0)
    px = bytearray(W * W * 4)
    step, o0 = 1.0 / SS, 1.0 / (2 * SS)

    for y in range(W):
        for x in range(W):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sy in range(SS):
                fy = y + o0 + sy * step
                for sx in range(SS):
                    fx = x + o0 + sx * step
                    if not maskable and not rrect(fx, fy, W, RX):
                        continue                      # 모서리 바깥은 투명
                    t = (fx + fy) / (2 * W)           # 대각선 그라데이션
                    bg = tuple(c0[i] + (c1[i] - c0[i]) * t for i in range(3))
                    hit = content((fx - off) / scale, (fy - off) / scale)
                    if hit:
                        col, a = hit
                        bg = tuple(col[i] * a + bg[i] * (1 - a) for i in range(3))
                    acc[0] += bg[0]; acc[1] += bg[1]; acc[2] += bg[2]; acc[3] += 1.0
            n = SS * SS
            o = (y * W + x) * 4
            if acc[3] == 0:
                continue
            for k in range(3):
                px[o + k] = max(0, min(255, int(round(acc[k] / acc[3]))))
            px[o + 3] = int(round(acc[3] / n * 255))
    return px

def upscale(px, w, factor):
    """정수배 확대 뒤 박스 평균 — 512 를 따로 그리지 않고 192 를 3배 부드럽게"""
    nw = w * factor
    out = bytearray(nw * nw * 4)
    for y in range(nw):
        for x in range(nw):
            sx, sy = x / factor, y / factor
            x0, y0 = min(int(sx), w - 1), min(int(sy), w - 1)
            x1, y1 = min(x0 + 1, w - 1), min(y0 + 1, w - 1)
            tx, ty = sx - x0, sy - y0
            o = (y * nw + x) * 4
            for k in range(4):
                a = px[(y0 * w + x0) * 4 + k] * (1 - tx) + px[(y0 * w + x1) * 4 + k] * tx
                b = px[(y1 * w + x0) * 4 + k] * (1 - tx) + px[(y1 * w + x1) * 4 + k] * tx
                out[o + k] = int(round(a * (1 - ty) + b * ty))
    return out, nw

def write_png(path, w, px):
    raw = bytearray()
    for y in range(w):
        raw.append(0); raw += px[y * w * 4:(y + 1) * w * 4]
    def ch(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    out  = b'\x89PNG\r\n\x1a\n'
    out += ch(b'IHDR', struct.pack('>IIBBBBB', w, w, 8, 6, 0, 0, 0))
    out += ch(b'IDAT', zlib.compress(bytes(raw), 9))
    out += ch(b'IEND', b'')
    open(path, 'wb').write(out)
    print(f'  {path}  {w}×{w}')

if __name__ == '__main__':
    print('아이콘 굽는 중…')
    for name, theme, mask in [('icon-192', 'book', False),
                              ('icon-192-maskable', 'book', True),
                              ('icon-admin', 'admin', False)]:
        px = render(theme, mask)
        write_png(f'{name}.png', W, px)
        if name != 'icon-admin':
            big, nw = upscale(px, W, 512 // W + 1)      # 192→576
            # 576 을 512 로 줄이지 않고 그대로 두면 파일만 커진다. 3배(576) 그대로 쓴다
            write_png(f'{name.replace("192", "512")}.png', nw, big)
    print('끝. 모서리 바깥은 투명, maskable 은 꽉 참.')
