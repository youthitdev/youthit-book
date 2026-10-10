-- 한끗독서 마이그레이션 115
-- 루틴마다 함께 읽은 쪽수
--
-- 【왜】 인증 탭 맨 위 「우리가 함께 쌓은 기록」을 「함께 N쪽을 읽었어요」로 바꾼다 (2026-10-10 사용자).
--   그러려면 루틴별 쪽수가 필요하다. 센 방식은 112·113 과 같다 (책: 늘어난 만큼·300쪽 상한, 글: 분량·100쪽 상한,
--   시작일 설정 적용).
--
-- 【내가 볼 수 있는 루틴만】 돌려주는 줄은 visible_routine_ids() 에 드는 루틴(같은 루틴 사람·끗짱)과, 운영진이면 전부다.
--   남의 루틴의 쪽수는 알 수 없다. 숫자 하나지만 어느 루틴이 얼마나 읽혔는지는 그 루틴 사람만 볼 일이다.
--
-- ⚠️ 23(visible_routine_ids) · 112·113 뒤에 돌린다.

CREATE OR REPLACE FUNCTION dokseo_routine_pages()
RETURNS TABLE (routine_id bigint, pages bigint) AS $$
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
    SELECT routine_id, cert_date,
           LEAST(300, GREATEST(0, page_end - COALESCE(
             MAX(page_end) OVER (PARTITION BY user_id, routine_id, bk
                                 ORDER BY cert_date, created_at, id
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))) AS n
      FROM base
  ), inc_shared AS (
    SELECT c.routine_id, c.cert_date, LEAST(100, c.page_end) AS n
      FROM certifications c
      JOIN routines r ON r.id = c.routine_id
     WHERE r.kind = 'shared' AND c.page_end IS NOT NULL AND c.page_end > 0
  ), inc AS (
    SELECT routine_id, cert_date, n FROM inc_book
    UNION ALL
    SELECT routine_id, cert_date, n FROM inc_shared
  )
  SELECT inc.routine_id, sum(inc.n)::bigint
    FROM inc, s
   WHERE inc.cert_date >= s.from_d
     AND (is_admin() OR inc.routine_id IN (SELECT visible_routine_ids()))
   GROUP BY inc.routine_id
$$ LANGUAGE sql STABLE SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION dokseo_routine_pages() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_routine_pages() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- SQL 편집기에서는 로그인한 사람이 없어 줄이 하나도 안 나올 수 있다 (정상). 함수가 만들어졌는지만 본다.
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_routine_pages') AS 함수_1이어야;
