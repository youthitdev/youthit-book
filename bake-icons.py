#!/usr/bin/env python3
"""logo-source.png 한 장에서 앱 아이콘을 전부 굽는다.  python3 bake-icons.py

원본은 1254px 짜리 스퀘어클 PNG 다. 그대로는 못 쓴다. 세 군데를 손본다.

1. 알파가 어디도 255 가 아니다 — 그림 전체가 250~254 사이다. 1% 쯤 비치는
   셈이라 검은 배경 위에서 색이 미세하게 죽는다. 제일 진한 값을 255 로 민다.
2. 스퀘어클이 정중앙이 아니다 — 왼쪽 4px, 위 9px 치우쳐 있다. 다시 맞춘다.
3. 파랑 배경에 잡티가 있다 — 눈에는 안 보여도 PNG 압축을 막는다.
   512px 한 장이 210KB 였다. 배경만 펴면 절반으로 준다. 책과 별의
   가장자리는 건드리지 않는다.

그리고 두 종류로 나눠 굽는다.

  모서리 비움 — 브라우저 탭. 스퀘어클 모양 그대로.
  모서리 채움 — 아이폰 홈 화면, 안드로이드 maskable.
                iOS 는 투명한 데를 검정으로 채운다. 전에 여기서 까만
                모서리가 생겼었다. 바깥은 스퀘어클 가장자리 색을 늘려 잇는다.
                단색으로 덮으면 곡선이 옅은 테두리로 비친다.

  책과 별은 지름의 75% 안에 들어 있다. maskable 안전영역(80%)보다 작으니
  따로 줄이지 않아도 잘리지 않는다.
"""
from PIL import Image, ImageFilter
import math, os

SRC = 'logo-source.png'


def load():
    im = Image.open(SRC).convert('RGBA')
    a = im.getchannel('A')
    top = max(v for v, n in enumerate(a.histogram()) if n)
    if top < 255:
        im.putalpha(a.point(lambda v: min(255, round(v * 255 / top))))
    box = im.getchannel('A').point(lambda v: 255 if v > 8 else 0).getbbox()
    cut = im.crop(box)
    s = max(cut.size)
    out = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    out.paste(cut, ((s - cut.width) // 2, (s - cut.height) // 2))
    return out


def background(im):
    """파랑 배경만 고른 마스크. B 가 R 보다 한참 크고 G 가 낮은 곳."""
    m = Image.new('L', im.size, 0)
    mp, ip = m.load(), im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = ip[x, y]
            if a > 200 and b > r + 60 and g < 130:
                mp[x, y] = 255
    return m


def smooth(im):
    m = background(im)
    m = m.filter(ImageFilter.MinFilter(9))      # 아트워크 가장자리에서 물러난다
    m = m.filter(ImageFilter.GaussianBlur(4))   # 경계를 부드럽게
    out = im.copy()
    out.paste(im.filter(ImageFilter.GaussianBlur(10)), (0, 0), m)
    return out


def fill_corners(im):
    src = im
    im = im.copy()
    px = im.load()
    w, h = im.size
    c = (w - 1) / 2
    for y in range(h):
        for x in range(w):
            if px[x, y][3] >= 250:
                continue
            dx, dy = c - x, c - y
            d = math.hypot(dx, dy) or 1
            dx, dy = dx / d, dy / d
            t = 0.0
            while t < d:
                t += 1.0
                p = px[int(round(x + dx * t)), int(round(y + dy * t))]
                if p[3] >= 250:
                    px[x, y] = (p[0], p[1], p[2], 255)
                    break
            else:
                px[x, y] = px[x, y][:3] + (255,)
    # 광선 한 줄씩 복사한 자리라 잔줄무늬가 남는다. 채운 데만 부드럽게 편다.
    hole = src.getchannel('A').point(lambda v: 0 if v >= 250 else 255)
    im.paste(im.filter(ImageFilter.GaussianBlur(8)), (0, 0),
             hole.filter(ImageFilter.GaussianBlur(2)))
    return im


def save(im, size, name):
    out = im.resize((size, size), Image.LANCZOS)
    # 색은 255가지로 줄이되 알파는 8비트 그대로 둔다. 팔레트(PNG-8)로 저장하면
    # 알파까지 뭉개져 스퀘어클 가장자리가 톱니가 된다.
    rgb = out.convert('RGB').quantize(
        colors=255, method=Image.MEDIANCUT, dither=Image.Dither.NONE).convert('RGB')
    res = rgb.convert('RGBA')
    res.putalpha(out.getchannel('A'))
    res.save(name, optimize=True)
    print(f'  {name:<24} {size}px  {os.path.getsize(name):,}B')


base = smooth(load())
print(f'원본 정리: 알파 255, 가운데 정렬, 배경 폄 ({base.size[0]}px)')
solid = fill_corners(base.resize((512, 512), Image.LANCZOS))

print('모서리 비움 — 브라우저 탭')
for s, n in [(32, 'icon-32.png'), (192, 'icon-192.png'), (512, 'icon-512.png')]:
    save(base, s, n)

print('모서리 채움 — 홈 화면')
for s, n in [(180, 'icon-apple.png'),
             (192, 'icon-192-maskable.png'), (512, 'icon-512-maskable.png')]:
    save(solid, s, n)
