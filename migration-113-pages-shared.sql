-- 한끗독서 마이그레이션 113
-- 「함께 읽는 글」에서도 읽은 쪽을 센다 (선택)
--
-- 【왜】 함께 읽는 글 루틴은 책도 쪽수도 없어서, 그 루틴만 하는 아이는 누적 쪽수가 영원히 0이었다.
--   이제 인증 화면에 「오늘 읽은 쪽」(선택)이 생긴다 (2026-10-10 사용자). 적으면 도시와 책 높이에 더해진다.
--
-- 【책 인증과 쪽수의 뜻이 다르다】 책 루틴의 쪽수(page_end)는 「그 책의 어디까지」(위치)라서 늘어난 만큼만 세지만,
--   글 루틴에는 책이 없어 위치라는 게 없다. 여기서는 쪽수를 **그날 읽은 분량**으로 보고 인증마다 그대로 더한다.
--   (한 인증에 100쪽까지 — 책보다 낮게 잡았다. 글 한 편이 그만큼 길 일이 없다)
--
-- 【112 를 이어받는다】 같은 함수(dokseo_pages_summary)를 다시 만든다. 책 쪽 계산은 그대로다.
--   함수 이름·반환 모양이 같아서 앱은 바꿀 것이 없다.
--
-- ⚠️ 112 뒤에 돌린다.

CREATE OR REPLACE FUNCTION dokseo_pages_summary() RETURNS jsonb AS $$
  WITH s AS (
    SELECT COALESCE((SELECT pages_count_from FROM dokseo_settings WHERE id = 1), DATE '2000-01-01') AS from_d
  ), base AS (
    -- 책 루틴: 책 제목이 있는 인증. 위치(page_end)가 늘어난 만큼 센다
    SELECT c.id, c.user_id, c.routine_id, c.cert_date, c.created_at, c.page_end,
           regexp_replace(lower(COALESCE(c.book_title, '')),
                          '[\s''"(),.\-:;!?‘’“”「」『』–—]', '', 'g') AS bk
      FROM certifications c
     WHERE c.page_end IS NOT NULL AND c.page_end > 0
       AND btrim(COALESCE(c.book_title, '')) <> ''
  ), inc_book AS (
    SELECT user_id, cert_date,
           LEAST(300, GREATEST(0, page_end - COALESCE(
             MAX(page_end) OVER (PARTITION BY user_id, routine_id, bk
                                 ORDER BY cert_date, created_at, id
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))) AS n
      FROM base
  ), inc_shared AS (
    -- 함께 읽는 글: 쪽수가 곧 그날 분량. 인증마다 그대로 (100쪽 상한)
    SELECT c.user_id, c.cert_date, LEAST(100, c.page_end) AS n
      FROM certifications c
      JOIN routines r ON r.id = c.routine_id
     WHERE r.kind = 'shared' AND c.page_end IS NOT NULL AND c.page_end > 0
  ), inc AS (
    SELECT user_id, cert_date, n FROM inc_book
    UNION ALL
    SELECT user_id, cert_date, n FROM inc_shared
  )
  SELECT jsonb_build_object(
    'total', COALESCE((SELECT sum(n) FROM inc, s WHERE inc.cert_date >= s.from_d), 0),
    'mine',  CASE WHEN auth.uid() IS NULL THEN NULL
                  ELSE COALESCE((SELECT sum(n) FROM inc, s WHERE inc.user_id = auth.uid() AND inc.cert_date >= s.from_d), 0) END,
    'from',  (SELECT pages_count_from FROM dokseo_settings WHERE id = 1)
  )
$$ LANGUAGE sql STABLE SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION dokseo_pages_summary() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION dokseo_pages_summary() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 112 에서 본 total 과 같거나 더 크다 (글 루틴에 쪽수를 적은 인증이 있으면 그만큼 늘어난다).
-- SQL 편집기에서는 mine 이 비어 있는 게 맞다 (null)
SELECT dokseo_pages_summary() AS 합계,
       (SELECT count(*) FROM routines WHERE kind = 'shared') AS 글루틴_수;
