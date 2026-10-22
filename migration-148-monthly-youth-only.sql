-- 한끗독서 마이그레이션 148
-- 월간 보고서의 「독서 기록」「읽은 청소년」「처음 인증한 사람」은 청소년만 센다 (2026-10-22 사용자)
--
-- 【왜】 28 의 월간 보고는 인증한 사람을 가리지 않고 셌다. 끗짱이나 시험으로 올린 관리자 계정의 인증까지 「청소년이 읽은 기록」에 섞였다.
--   후원 보고서에 나가는 숫자이므로 청소년만 세도록 맞춘다 (관리자 통계·리포트가 쓰는 기준과 같다).
--
-- 【무엇을】
--   · 청소년 판별 함수 report_is_youth(사용자): role 이 청소년이고 끗짱(can_lead)이 아니고 운영진이 아니면 참이다.
--   · dokseo_monthly_report: 독서 기록(certs) · 읽은 청소년(readers) · 처음 인증한 사람(new_readers)이 청소년만 센다.
--   · **매일 한끗(상시 루틴)의 인증도 함께 센다** — 책을 읽은 기록이기 때문이다. 루틴을 가리지 않는다.
--
-- 【그대로인 것】 읽은 쪽수(pages)·읽은 책 목록(books_read)·루틴 참여(joins)·루틴 수·전해진 책·후원·후기·문장은 28 판과 같다.
--   (관리자 계정의 시험 참여가 있으면 「루틴 참여」에는 아직 들어간다 — 필요하면 따로 고친다)
--
-- ⚠️ 28 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION report_is_youth(p_user uuid) RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles p
     WHERE p.id = p_user AND COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
       AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id))
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION report_is_youth(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION dokseo_monthly_report(p_year int, p_month int)
RETURNS jsonb AS $$
DECLARE
  d0 date; d1 date; r jsonb;
BEGIN
  -- SQL 편집기에는 auth.email() 이 없어 is_admin() 이 false 가 된다.
  -- 익명은 아래 REVOKE 로 실행 자체가 막혀 있고, 로그인한 사람은 auth.uid() 가
  -- 항상 있으므로, uid 가 없는 경우(=SQL 편집기)만 통과시키는 게 안전하다
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;
  IF p_year IS NULL OR p_month IS NULL OR p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION '연월이 올바르지 않습니다';
  END IF;

  d0 := make_date(p_year, p_month, 1);
  d1 := (d0 + interval '1 month')::date;   -- 다음 달 1일. 비교는 항상 [d0, d1)

  SELECT jsonb_build_object(
    'year',  p_year,
    'month', p_month,

    -- ── 읽기 ──────────────────────────────────────────
    -- 청소년만 센다 (2026-10-22 사용자): 끗짱·운영진·어른의 인증은 뺀다. 매일 한끗의 인증은 책을 읽은 기록이라 함께 센다
    'readers', (SELECT count(DISTINCT user_id) FROM certifications
                 WHERE cert_date >= d0 AND cert_date < d1 AND report_is_youth(user_id)),
    'certs',   (SELECT count(*) FROM certifications
                 WHERE cert_date >= d0 AND cert_date < d1 AND report_is_youth(user_id)),
    'pages',   (SELECT COALESCE(sum(page_end), 0) FROM certifications
                 WHERE cert_date >= d0 AND cert_date < d1 AND page_end IS NOT NULL),
    -- 이 달에 처음 인증한 사람 (그 전에는 한 번도 없던 사람)
    'new_readers', (SELECT count(*) FROM (
        SELECT user_id, min(cert_date) AS first_day
          FROM certifications WHERE report_is_youth(user_id) GROUP BY user_id
      ) t WHERE t.first_day >= d0 AND t.first_day < d1),

    -- ── 루틴 ──────────────────────────────────────────
    'joins',    (SELECT count(*) FROM routine_participants
                  WHERE status = 'approved' AND joined_at >= d0 AND joined_at < d1),
    'routines_running', (SELECT count(*) FROM routines
                  WHERE start_date < d1 AND (end_date IS NULL OR end_date >= d0)),

    -- ── 책 ────────────────────────────────────────────
    -- 정산이 확정된 것만 "전해진 책" 이다. 신청만 하고 정산 전이면 안 센다
    'books',      (SELECT count(*) FROM book_purchases
                    WHERE status = 'settled' AND settled_at >= d0 AND settled_at < d1),
    'book_spent', (SELECT COALESCE(sum(amount), 0) FROM book_purchases
                    WHERE status = 'settled' AND settled_at >= d0 AND settled_at < d1),
    'books_waiting', (SELECT count(*) FROM book_purchases
                    WHERE status = 'pending' AND created_at < d1),
    'stores', (SELECT COALESCE(jsonb_agg(x ORDER BY x->>'name'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object('name', s.name, 'region', s.region, 'books', count(*)) AS x
          FROM book_purchases b JOIN bookstores s ON s.id = b.bookstore_id
         WHERE b.status = 'settled' AND b.settled_at >= d0 AND b.settled_at < d1
         GROUP BY s.name, s.region
      ) t),

    -- ── 아이들이 읽은 책 ───────────────────────────────
    -- 인증에 적힌 책과 참여할 때 적은 책을 합친다. 같은 책을 여럿이 읽으면
    -- 한 줄로 묶고 몇 명인지 센다. 제목만 담는다 — 누가 읽었는지는 안 담는다
    'books_read', (SELECT COALESCE(jsonb_agg(
        jsonb_build_object('title', title, 'readers', readers) ORDER BY readers DESC, title
      ), '[]'::jsonb) FROM (
        SELECT btrim(title) AS title, count(DISTINCT user_id) AS readers FROM (
          SELECT book_title AS title, user_id FROM certifications
           WHERE cert_date >= d0 AND cert_date < d1
          UNION ALL
          SELECT book_title, user_id FROM routine_participants
           WHERE status = 'approved' AND joined_at >= d0 AND joined_at < d1
        ) u
        WHERE COALESCE(btrim(title), '') <> ''
        GROUP BY btrim(title)
      ) t),

    -- ── 후원 ──────────────────────────────────────────
    'donated', (SELECT COALESCE(sum(amount), 0) FROM charges
                 WHERE charged_at >= d0 AND charged_at < d1),
    'donors',  (SELECT count(DISTINCT sponsor_id) FROM charges
                 WHERE charged_at >= d0 AND charged_at < d1),
    'pool',    dokseo_pool_status(),

    -- ── 아이들의 말 (운영진이 공개로 고른 것만, 이름 없이) ──
    'reviews', (SELECT COALESCE(jsonb_agg(
        jsonb_build_object('kind', kind, 'book_title', book_title, 'content', content)
        ORDER BY created_at DESC), '[]'::jsonb)
       FROM reviews
      WHERE is_public AND created_at >= d0 AND created_at < d1),
    'quotes', (SELECT COALESCE(jsonb_agg(
        jsonb_build_object('quote', quote, 'book_title', book_title, 'day', cert_date)
        ORDER BY cert_date DESC), '[]'::jsonb)
       FROM certifications
      WHERE quote_public AND COALESCE(btrim(quote), '') <> ''
        AND cert_date >= d0 AND cert_date < d1)
  ) INTO r;

  RETURN r;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION dokseo_monthly_report(int, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_monthly_report(int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 함수 2 · 새 판 1 / 이번 달 숫자 (예전과 비교해 끗짱·관리자 몫만큼 줄 수 있다)
SELECT (SELECT count(*) FROM pg_proc WHERE proname IN ('report_is_youth', 'dokseo_monthly_report'))                    AS 함수_2여야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_monthly_report' AND prosrc LIKE '%report_is_youth%')       AS 새판_1이어야,
       (dokseo_monthly_report(extract(year FROM now())::int, extract(month FROM now())::int) ->> 'certs')              AS 이번달_독서기록,
       (dokseo_monthly_report(extract(year FROM now())::int, extract(month FROM now())::int) ->> 'readers')            AS 이번달_읽은청소년,
       (dokseo_monthly_report(extract(year FROM now())::int, extract(month FROM now())::int) ->> 'new_readers')        AS 이번달_처음인증;
