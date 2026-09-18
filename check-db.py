#!/usr/bin/env python3
"""DB 점검.  python3 check-db.py

마이그레이션은 돌렸다고 나오는데 실제로는 안 들어가 있는 일이 있었다
(routine_participants.book_title). PostgreSQL 은 함수를 만들 때 그 안의
컬럼을 검사하지 않아서, ALTER TABLE 만 빠져도 'Success' 로 끝난다.

그래서 이 스크립트는 **SQL 파일이 아니라 실제 DB** 에 물어본다.
  1. .sql 들에서 '있어야 할 컬럼' 을 뽑고
  2. PostgREST 에 하나씩 물어 없는 걸 찾아내고
  3. 익명이 부르면 안 되는 함수가 정말 막혀 있는지 확인한다

바깥 라이브러리 없이 표준 라이브러리만 쓴다.
"""
import json, re, sys, urllib.request, urllib.error
from pathlib import Path

HERE = Path(__file__).parent
APP  = (HERE / 'app.html').read_text(encoding='utf-8')
URL  = re.search(r"SB_URL\s*=\s*'([^']+)'", APP).group(1)
KEY  = re.search(r"SB_KEY\s*=\s*'([^']+)'", APP).group(1)

# 익명이 부르면 안 되는 함수 — 뚫려 있으면 사고다.
# 인자가 있는 건 채워서 부른다. 안 그러면 PostgREST 가 서명을 못 찾아
# 404 를 주고, 막혔는지 아닌지를 알 수 없다.
# 인자를 줘도 안전하다 — 전부 첫 줄에서 is_admin() 을 보고 튕긴다
MUST_BLOCK = {
    'settle_book_purchase':    {'p_purchase_id': 0, 'p_amount': 1},
    'mark_purchase_paid':      {'p_purchase_id': 0},
    'decide_kkut_application': {'p_user': '00000000-0000-0000-0000-000000000000',
                                'p_approve': False, 'p_reason': 'check'},
    'invite_kkut':             {'p_email': 'check@example.invalid'},
    'kkut_applications_admin': {},
    'dokseo_points':           {},
    'is_approved_kkut':        {},
    'cert_days':               {},
    'kkut_eligibility':        {},
    'visible_routine_ids':     {},
    'visible_user_ids':        {},
    'can_see_cert':            {'p_cert': 0},
    'dokseo_monthly_report':   {'p_year': 2026, 'p_month': 1},
    'review_due':              {'p_routine': 0},
}
# 익명도 볼 수 있어야 하는 것 — 랜딩·후원자 화면이 이걸로 돈다
MUST_WORK  = ['dokseo_reading_stats', 'dokseo_pool_status', 'routine_people_count',
              'dokseo_books_reading', 'dokseo_public_quotes', 'dokseo_public_reviews',
              'dokseo_activity_feed', 'dokseo_sponsor_wall', 'dokseo_book_photos']
SKIP_TABLES = {'auth.users', 'storage.buckets', 'storage.objects'}


def req(path, body=None):
    r = urllib.request.Request(
        URL + path, data=None if body is None else json.dumps(body).encode(),
        headers={'apikey': KEY, 'Authorization': 'Bearer ' + KEY,
                 'Content-Type': 'application/json'},
        method='POST' if body is not None else 'GET')
    try:
        with urllib.request.urlopen(r, timeout=20) as f:
            return f.status, f.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:
        return 0, str(e)


def expected_columns():
    """.sql 들에서 CREATE TABLE 과 ALTER TABLE ... ADD COLUMN 을 긁는다"""
    want = {}
    noise = re.compile(r'^\s*(CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE|LIKE)\b', re.I)
    for f in sorted(HERE.glob('*.sql')):
        sql = f.read_text(encoding='utf-8')
        sql = re.sub(r'--[^\n]*', '', sql)           # 주석 제거

        for m in re.finditer(r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([\w.]+)\s*\((.*?)\n\);',
                             sql, re.S | re.I):
            t, body = m.group(1), m.group(2)
            if t in SKIP_TABLES: continue
            cols = want.setdefault(t, set())
            depth = 0
            for line in body.split('\n'):
                s = line.strip()
                if not s or noise.match(s):
                    depth += s.count('(') - s.count(')'); continue
                if depth == 0:
                    c = re.match(r'([a-z_][a-z0-9_]*)\s', s)
                    if c: cols.add(c.group(1))
                depth += s.count('(') - s.count(')')

        for m in re.finditer(r'ALTER\s+TABLE\s+([\w.]+)\s+ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?([a-z_][a-z0-9_]*)',
                             sql, re.I):
            t, c = m.group(1), m.group(2)
            if t not in SKIP_TABLES:
                want.setdefault(t, set()).add(c)
    return want


def main():
    print(f'\n대상 {URL}\n')
    bad = 0

    print('── 컬럼 ──────────────────────────────────────────────')
    for table, cols in sorted(expected_columns().items()):
        cols = sorted(cols)
        st, body = req(f'/rest/v1/{table}?select={",".join(cols)}&limit=1')
        if st == 200:
            print(f'  ✅ {table:<24} {len(cols)}개')
            continue
        if 'does not exist' not in body and 'Could not find' not in body:
            print(f'  ⚠️  {table:<24} 확인 못 함 — {body[:80]}')
            continue
        missing = []
        for c in cols:
            s2, b2 = req(f'/rest/v1/{table}?select={c}&limit=1')
            if s2 != 200 and ('does not exist' in b2 or 'Could not find' in b2):
                missing.append(c)
        bad += len(missing)
        print(f'  ❌ {table:<24} 없음: {", ".join(missing)}')

    print('\n── 익명이 부르면 안 되는 함수 ────────────────────────')
    for fn, args in MUST_BLOCK.items():
        st, body = req(f'/rest/v1/rpc/{fn}', args)
        if st in (401, 403) or 'permission denied' in body:
            print(f'  ✅ {fn:<26} 막힘')
        elif st == 404:
            bad += 1
            print(f'  ❌ {fn:<26} 함수가 없음 — 마이그레이션 확인')
        else:
            bad += 1
            print(f'  ❌ {fn:<26} 뚫림! ({st}) {body[:70]}')

    print('\n── 익명도 볼 수 있어야 하는 것 ───────────────────────')
    for fn in MUST_WORK:
        st, body = req(f'/rest/v1/rpc/{fn}', {})
        # 인자가 필요한 함수는 400 이 정상 (호출 자체는 열려 있다는 뜻)
        if st == 200 or (st == 404 and 'without parameters' in body):
            print(f'  ✅ {fn:<26}')
        elif st == 404:
            bad += 1
            print(f'  ❌ {fn:<26} 함수가 없음')
        else:
            bad += 1
            print(f'  ❌ {fn:<26} ({st}) {body[:60]}')

    print()
    if bad:
        print(f'⚠️  {bad}군데 문제가 있습니다. 위 항목의 마이그레이션을 다시 실행하세요.\n')
        sys.exit(1)
    print('다 맞습니다.\n')


if __name__ == '__main__':
    main()
