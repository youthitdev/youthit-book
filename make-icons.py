#!/usr/bin/env python3
"""아이콘 생성기.  python3 make-icons.py

SVG 를 손으로 고치면 PNG 가 따로 놀기 때문에 한 곳에서 같이 굽는다.
바깥 라이브러리 없이 순수 파이썬으로 그린다 (맥에 SVG 래스터라이저가 없다).
모양이 몇 개뿐이라 직접 그리는 편이 도구를 까는 것보다 빨랐다.

빠르기 — 픽셀마다 다각형을 훑으면 512px 에서 몇 분이 걸린다. 그래서
가로줄(스캔라인)마다 교차점을 한 번만 구해두고 그 줄의 점들은 그걸 재사용한다.
"""
import struct, zlib, math, re

SS   = 4          # 픽셀당 4×4 초과표본
BASE = 192.0      # 모든 좌표는 192 기준
RX   = 44.0       # 둥근 모서리
GOLD = (0xFF, 0xD6, 0x00)

BOOK_L = "M96 62 C82 52, 60 50, 44 54 L44 134 C60 130, 82 132, 96 142 Z"
BOOK_R = "M96 62 C110 52, 132 50, 148 54 L148 134 C132 130, 110 132, 96 142 Z"

# ── 경로 → 다각형 ───────────────────────────────────────
def flatten(d, steps=28):
    toks = re.findall(r'[MCLZ]|-?\d+\.?\d*', d)
    pts, i, cur = [], 0, (0.0, 0.0)
    while i < len(toks):
        t = toks[i]; i += 1
        if t in 'ML':
            cur = (float(toks[i]), float(toks[i+1])); i += 2; pts.append(cur)
        elif t == 'C':
            p1 = (float(toks[i]),   float(toks[i+1]))
            p2 = (float(toks[i+2]), float(toks[i+3]))
            p3 = (float(toks[i+4]), float(toks[i+5])); i += 6
            for s in range(1, steps + 1):
                u = s / steps; v = 1 - u
                pts.append((v*v*v*cur[0] + 3*v*v*u*p1[0] + 3*v*u*u*p2[0] + u*u*u*p3[0],
                            v*v*v*cur[1] + 3*v*v*u*p1[1] + 3*v*u*u*p2[1] + u*u*u*p3[1]))
            cur = p3
    return pts

def crossings(poly, yy):
    """이 가로줄에서 다각형 경계를 지나는 x 들 (정렬)"""
    xs = []
    n = len(poly); j = n - 1
    for i in range(n):
        xi, yi = poly[i]; xj, yj = poly[j]
        if (yi > yy) != (yj > yy):
            xs.append((xj - xi) * (yy - yi) / (yj - yi) + xi)
        j = i
    xs.sort()
    return xs

def in_spans(xs, x):
    c = 0
    for v in xs:
        if v > x: break
        c += 1
    return c % 2 == 1

def seg_dist(px_, py, x1, y1, x2, y2):
    dx, dy = x2 - x1, y2 - y1
    t = 0.0 if (dx == 0 and dy == 0) else max(0.0, min(1.0,
        ((px_ - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px_ - (x1 + t * dx), py - (y1 + t * dy))

# 유스보이스 로고의 실측값은 굵기 8% · 각도 ±37 · 구멍 0.26 인데,
# 아이콘 안에서는 그 비율이 너무 가늘어 보인다. 책·고리와 나란히 섰을 때
# 눈에 들어오는 굵기로 맞춘다 (2026-09-17 결정)
SPARK_ANGLE = 30      # 대각선 각도
SPARK_INNER = 0.36    # 가운데 빈 구멍 / 바깥 반지름

def spark(cx, cy, R, w, inner_ratio=SPARK_INNER, ang=SPARK_ANGLE):
    """유스보이스 마크 — 가운데가 빈 6갈래. 세로 2 + 대각선 4"""
    inner = R * inner_ratio
    segs = []
    for a in (-90, 90, -180 + ang, -ang, 180 - ang, ang):
        r = math.radians(a)
        segs.append((cx + math.cos(r)*inner, cy + math.sin(r)*inner,
                     cx + math.cos(r)*R,     cy + math.sin(r)*R))
    return {'kind': 'spark', 'segs': segs, 'w': w, 'color': GOLD, 'alpha': 1.0,
            'bbox': (cx - R - w, cy - R - w, cx + R + w, cy + R + w)}

def scale_about(pts, k, cx=96.0, cy=96.0):
    return [(cx + (x - cx) * k, cy + (y - cy) * k) for x, y in pts]

def poly(d, color=(255,255,255), alpha=1.0, k=1.0):
    p = flatten(d)
    if k != 1.0: p = scale_about(p, k)
    xs = [q[0] for q in p]; ys = [q[1] for q in p]
    return {'kind': 'poly', 'pts': p, 'color': color, 'alpha': alpha,
            'bbox': (min(xs), min(ys), max(xs), max(ys))}

def ring(cx, cy, r, w, color=(255,255,255), alpha=1.0):
    return {'kind': 'ring', 'c': (cx, cy), 'r': r, 'w': w, 'color': color, 'alpha': alpha,
            'bbox': (cx - r - w, cy - r - w, cx + r + w, cy + r + w)}

# ── 그리기 ──────────────────────────────────────────────
# bleed=True  모서리를 깎지 않고 꽉 채운다 (홈 화면용)
# k           내용 크기. 안드로이드 maskable 은 0.72 로 줄여 안전영역에 넣고,
#             아이폰은 스퀘어클로 조금만 깎으므로 0.88 이면 충분하다.
#             전에는 아이폰에도 0.72 짜리를 줘서 그림이 작아 보였다
def render(size, c0, c1, shapes, bleed=False, k=1.0):
    scale, off = k, BASE * (1 - k) / 2
    maskable = bleed
    k = BASE / size                      # 출력 픽셀 → 192 좌표
    px_ = bytearray(size * size * 4)
    step, o0 = 1.0 / SS, 1.0 / (2 * SS)

    for y in range(size):
        # 이 픽셀 행이 품는 SS 개 가로줄마다 다각형 교차점을 미리 구해 둔다
        rows = []
        for sy in range(SS):
            fy = (y + o0 + sy * step) * k
            uy = (fy - off) / scale
            rows.append((fy, uy, [crossings(s['pts'], uy) if s['kind'] == 'poly' else None
                                  for s in shapes]))
        for x in range(size):
            acc = [0.0, 0.0, 0.0, 0.0]
            for sx in range(SS):
                fx = (x + o0 + sx * step) * k
                for fy, uy, xs_list in rows:
                    if not maskable:
                        cx_ = RX if fx < RX else (BASE - RX if fx > BASE - RX else fx)
                        cy_ = RX if fy < RX else (BASE - RX if fy > BASE - RX else fy)
                        if (fx - cx_) ** 2 + (fy - cy_) ** 2 > RX * RX:
                            continue                     # 모서리 바깥은 투명
                    t = (fx + fy) / (2 * BASE)
                    col = [c0[i] + (c1[i] - c0[i]) * t for i in range(3)]
                    ux = (fx - off) / scale
                    for si, s in enumerate(shapes):
                        bx0, by0, bx1, by1 = s['bbox']
                        if not (bx0 <= ux <= bx1 and by0 <= uy <= by1): continue
                        hit = False
                        if s['kind'] == 'poly':
                            hit = in_spans(xs_list[si], ux)
                        elif s['kind'] == 'ring':
                            dd = math.hypot(ux - s['c'][0], uy - s['c'][1])
                            hit = abs(dd - s['r']) <= s['w'] / 2
                        else:
                            hit = any(seg_dist(ux, uy, *g) <= s['w'] / 2 for g in s['segs'])
                        if hit:
                            a = s['alpha']
                            col = [s['color'][i] * a + col[i] * (1 - a) for i in range(3)]
                    acc[0] += col[0]; acc[1] += col[1]; acc[2] += col[2]; acc[3] += 1.0
            o = (y * size + x) * 4
            if acc[3] == 0: continue
            for i in range(3):
                px_[o + i] = max(0, min(255, int(round(acc[i] / acc[3]))))
            px_[o + 3] = int(round(acc[3] / (SS * SS) * 255))
    return px_

def write_png(path, size, px_):
    raw = bytearray()
    for y in range(size):
        raw.append(0); raw += px_[y * size * 4:(y + 1) * size * 4]
    def ch(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    out  = b'\x89PNG\r\n\x1a\n'
    out += ch(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
    out += ch(b'IDAT', zlib.compress(bytes(raw), 9))
    out += ch(b'IEND', b'')
    open(path, 'wb').write(out)
    print(f'  {path}  {size}×{size}')

# ── 한끗독서 ────────────────────────────────────────────
# 책이 가로는 고리와 같은데 세로로 짧아 작아 보였다 (74×65 대 74×74).
# 가운데를 기준으로 키운다
BOOK_K = 1.15
BOOK   = lambda: [poly(BOOK_L, k=BOOK_K), poly(BOOK_R, alpha=0.82, k=BOOK_K),
                  spark(142, 46, 22, 9)]
BLUE   = ((0x3A, 0x40, 0xD6), (0x2A, 0x2F, 0xA8))
PINK   = ((0xFF, 0x3D, 0x7F), (0xE0, 0x00, 0x5C))

if __name__ == '__main__':
    print('한끗독서 아이콘 굽는 중…')
    #        파일                      크기  색    꽉참   내용크기
    jobs = [('icon-192.png',           192, BLUE, False, 1.00),   # 탭 — 모서리 투명
            ('icon-512.png',           512, BLUE, False, 1.00),
            ('icon-192-maskable.png',  192, BLUE, True,  0.72),   # 안드로이드
            ('icon-512-maskable.png',  512, BLUE, True,  0.72),
            ('icon-apple.png',         192, BLUE, True,  0.88),   # 아이폰 홈 화면
            ('icon-apple-512.png',     512, BLUE, True,  0.88),
            ('icon-admin.png',         192, PINK, False, 1.00)]
    for name, size, (c0, c1), bleed, k in jobs:
        write_png(name, size, render(size, c0, c1, BOOK(), bleed, k))
    print('끝. 탭은 모서리 투명, 홈 화면(maskable·apple)은 꽉 참.')
