-- 한끗독서 마이그레이션 114
-- 끗짱 성과 카드에 「아이들이 읽은 쪽수」
--
-- 【왜】 끗짱의 「함께 쌓은 기록」에는 함께한 청소년 수·읽은 날·읽은 책만 있었다. 끗짱이 이끈 루틴에서
--   아이들이 읽은 쪽수가 궁금하다 (2026-10-10 사용자). 끗짱 개인의 책 높이와는 따로다 — 내가 읽은 것이 아니라
--   내가 함께한 아이들이 읽은 것이다.
--
-- 【같은 함수에 한 칸을 더한다】 dokseo_pages_summary 의 반환에 'kids' 를 더한다. 앱은 같은 호출 하나로 받는다.
--   세는 방식은 112·113 과 같다 (책: 늘어난 만큼·300쪽 상한, 글: 분량·100쪽 상한, 시작일 설정 적용).
--   'kids' 는 로그인한 사람이 **끗짱으로 맡은 루틴**의 아이들(끗짱 본인 제외)만 센다. 맡은 루틴이 없으면 0.
--
-- ⚠️ 112·113 뒤에 돌린다.

CREATE OR REPLACE FUNCTION dokseo_pages_summary() RETURNS jsonb AS $$
  WITH s AS (
    SELECT COALESCE((SELECT pages_count_from FROM dokseo_settings WHERE id = 1), DATE '2000-01-01') AS from_d
  ), base AS (
    SELECT c.id, c.user_id, c.routine_id, c.cert_date, c.created_at, c.page_end,
           regexp_replace(lower(COALESCE(c.book_title, '')),
                          '[\s''"(),.\-:;!?‘’“”「」『』–—]', '', 'g') AS bk
      FROM certifications c
     WHERE c.page_end IS NOT NULL AND c.page_end > 0
       AND btrim(COALESCE(c.book_title, '')) <> ''
  ), inc_book AS (
    SELECT user_id, routine_id, cert_date,
           LEAST(300, GREATEST(0, page_end - COALESCE(
             MAX(page_end) OVER (PARTITION BY user_id, routine_id, bk
                                 ORDER BY cert_date, created_at, id
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))) AS n
      FROM base
  ), inc_shared AS (
    SELECT c.user_id, c.routine_id, c.cert_date, LEAST(100, c.page_end) AS n
      FROM certifications c
      JOIN routines r ON r.id = c.routine_id
     WHERE r.kind = 'shared' AND c.page_end IS NOT NULL AND c.page_end > 0
  ), inc AS (
    SELECT user_id, routine_id, cert_date, n FROM inc_book
    UNION ALL
    SELECT user_id, routine_id, cert_date, n FROM inc_shared
  )
  SELECT jsonb_build_object(
    'total', COALESCE((SELECT sum(n) FROM inc, s WHERE inc.cert_date >= s.from_d), 0),
    'mine',  CASE WHEN auth.uid() IS NULL THEN NULL
                  ELSE COALESCE((SELECT sum(n) FROM inc, s WHERE inc.user_id = auth.uid() AND inc.cert_date >= s.from_d), 0) END,
    -- 내가 끗짱으로 맡은 루틴에서 아이들이 읽은 쪽수 (나 자신은 뺀다)
    'kids',  CASE WHEN auth.uid() IS NULL THEN NULL
                  ELSE COALESCE((SELECT sum(n) FROM inc
                                  JOIN routines r ON r.id = inc.routine_id, s
                                 WHERE r.led_by = auth.uid() AND inc.user_id <> auth.uid()
                                   AND inc.cert_date >= s.from_d), 0) END,
    'from',  (SELECT pages_count_from FROM dokseo_settings WHERE id = 1)
  )
$$ LANGUAGE sql STABLE SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION dokseo_pages_summary() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION dokseo_pages_summary() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- SQL 편집기에서는 로그인한 사람이 없어 mine·kids 가 null 인 게 맞다. total 은 113 때와 같다.
SELECT dokseo_pages_summary() AS 합계,
       (SELECT prosrc LIKE '%''kids''%' FROM pg_proc WHERE proname = 'dokseo_pages_summary') AS 아이쪽수_반영됨;
