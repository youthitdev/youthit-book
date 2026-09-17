-- 한끗독서 마이그레이션 28
-- 후원자에게 보낼 월간 보고서를 한 번에 뽑는다
--
-- 매달 손으로 여러 쿼리를 돌려 숫자를 옮겨 적으면 반드시 틀린다.
-- 함수 하나로 모으고, 관리자 화면이 그걸 그대로 읽어 문자 본문까지 만든다.
--
-- 운영진만 부를 수 있다. 아이들의 후기와 문장은 "공개로 고른 것" 만 담는다 —
-- 이름은 어디에도 넣지 않는다.

CREATE OR REPLACE FUNCTION dokseo_monthly_report(p_year int, p_month int)
RETURNS jsonb AS $$
DECLARE
  d0 date; d1 date; r jsonb;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  IF p_year IS NULL OR p_month IS NULL OR p_month < 1 OR p_month > 12 THEN
    RAISE EXCEPTION '연월이 올바르지 않습니다';
  END IF;

  d0 := make_date(p_year, p_month, 1);
  d1 := (d0 + interval '1 month')::date;   -- 다음 달 1일. 비교는 항상 [d0, d1)

  SELECT jsonb_build_object(
    'year',  p_year,
    'month', p_month,

    -- ── 읽기 ──────────────────────────────────────────
    'readers', (SELECT count(DISTINCT user_id) FROM certifications
                 WHERE cert_date >= d0 AND cert_date < d1),
    'certs',   (SELECT count(*) FROM certifications
                 WHERE cert_date >= d0 AND cert_date < d1),
    'pages',   (SELECT COALESCE(sum(page_end), 0) FROM certifications
                 WHERE cert_date >= d0 AND cert_date < d1 AND page_end IS NOT NULL),
    -- 이 달에 처음 인증한 사람 (그 전에는 한 번도 없던 사람)
    'new_readers', (SELECT count(*) FROM (
        SELECT user_id, min(cert_date) AS first_day
          FROM certifications GROUP BY user_id
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

-- 함수를 만들면 PUBLIC 에 EXECUTE 가 기본으로 붙는다. 명시적으로 회수한다
REVOKE EXECUTE ON FUNCTION dokseo_monthly_report(int, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_monthly_report(int, int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ↓ 이번 달 보고서. 표가 한 줄 나와야 성공이다
SELECT dokseo_monthly_report(
  EXTRACT(year  FROM (now() AT TIME ZONE 'Asia/Seoul'))::int,
  EXTRACT(month FROM (now() AT TIME ZONE 'Asia/Seoul'))::int);
