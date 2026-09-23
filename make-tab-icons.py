#!/usr/bin/env python3
"""랜딩·파트너 탭 구분용 아이콘 생성기.  python3 make-tab-icons.py

관리자 창을 색으로 구분하는 make-icons.py 와 같은 방식 — 브라우저 탭이
여러 개 떠 있을 때 한끗독서 앱/랜딩/파트너 페이지를 색으로 구분한다.
랜딩은 index.html 의 --green(#83CA00), 파트너는 앱 공용 --gold(#FFD600)
를 그대로 써서 각 페이지 자체 배색과 맞춘다.
"""
import struct, zlib, math, re

SS   = 4
BASE = 192.0
RX   = 44.0

BOOK_L = "M96 62 C82 52, 60 50, 44 54 L44 134 C60 130, 82 132, 96 142 Z"
BOOK_R = "M96 62 C110 52, 132 50, 148 54 L148 134 C132 130, 110 132, 96 142 Z"

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

SPARK_ANGLE = 30
SPARK_INNER = 0.36

def spark(cx, cy, R, w, color, inner_ratio=SPARK_INNER, ang=SPARK_ANGLE):
    inner = R * inner_ratio
    segs = []
    for a in (-90, 90, -180 + ang, -ang, 180 - ang, ang):
        r = math.radians(a)
        segs.append((cx + math.cos(r)*inner, cy + math.sin(r)*inner,
                     cx + math.cos(r)*R,     cy + math.sin(r)*R))
    return {'kind': 'spark', 'segs': segs, 'w': w, 'color': color, 'alpha': 1.0,
            'bbox': (cx - R - w, cy - R - w, cx + R + w, cy + R + w)}

def scale_about(pts, k, cx=96.0, cy=96.0):
    return [(cx + (x - cx) * k, cy + (y - cy) * k) for x, y in pts]

def poly(d, color=(255,255,255), alpha=1.0, k=1.0):
    p = flatten(d)
    if k != 1.0: p = scale_about(p, k)
    xs = [q[0] for q in p]; ys = [q[1] for q in p]
    return {'kind': 'poly', 'pts': p, 'color': color, 'alpha': alpha,
            'bbox': (min(xs), min(ys), max(xs), max(ys))}

def render(size, c0, c1, shapes, k=1.0):
    scale, off = k, BASE * (1 - k) / 2
    k = BASE / size
    px_ = bytearray(size * size * 4)
    step, o0 = 1.0 / SS, 1.0 / (2 * SS)

    for y in range(size):
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
                    cx_ = RX if fx < RX else (BASE - RX if fx > BASE - RX else fx)
                    cy_ = RX if fy < RX else (BASE - RX if fy > BASE - RX else fy)
                    if (fx - cx_) ** 2 + (fy - cy_) ** 2 > RX * RX:
                        continue
                    t = (fx + fy) / (2 * BASE)
                    col = [c0[i] + (c1[i] - c0[i]) * t for i in range(3)]
                    ux = (fx - off) / scale
                    for si, s in enumerate(shapes):
                        bx0, by0, bx1, by1 = s['bbox']
                        if not (bx0 <= ux <= bx1 and by0 <= uy <= by1): continue
                        hit = False
                        if s['kind'] == 'poly':
                            hit = in_spans(xs_list[si], ux)
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

BOOK_K = 1.15
def book(): return [poly(BOOK_L, k=BOOK_K), poly(BOOK_R, alpha=0.82, k=BOOK_K)]

GREEN   = ((0x83, 0xCA, 0x00), (0x4E, 0x7A, 0x00))   # index.html --green → --green-d
GOLD_BG = ((0xFF, 0xD6, 0x00), (0xE0, 0xB8, 0x00))   # 앱 공용 --gold
BLUE    = (0x2E, 0x33, 0xBC)                          # 파트너: 노란 배경 위 골드 스파크는 안 보여서 앱 기본 파랑으로 교체
GOLD    = (0xFF, 0xD6, 0x00)

if __name__ == '__main__':
    print('탭 구분 아이콘 굽는 중…')
    write_png('icon-landing.png', 192, render(192, *GREEN, book() + [spark(142, 46, 22, 9, GOLD)]))
    write_png('icon-partner.png', 192, render(192, *GOLD_BG, book() + [spark(142, 46, 22, 9, BLUE)]))
    print('끝. icon-landing.png, icon-partner.png')
