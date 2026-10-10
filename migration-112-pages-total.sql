-- 한끗독서 마이그레이션 112
-- 누적 쪽수 — 함께 읽은 전체 쪽수와 내가 읽은 쪽수를 서버에서 센다
--
-- 【왜】 「함께 짓는 한끗 책의 도시」(전체)와 「내가 쌓은 책 높이」(개인)를 보여 주려면 믿을 만한 합계가 필요하다.
--   앱은 최근 인증 300건만 들고 있어서 앱에서는 셀 수 없다. 서버에서 한 번에 센다.
--
-- 【어떻게 세나 — 쪽수는 「지금까지 읽은 위치」다】 인증의 쪽수(page_end)는 그날 읽은 양이 아니라 그 책의 어디까지
--   읽었나이다. 인증마다 더하면 같은 쪽이 겹쳐 세어진다 (월간 보고(28)가 이렇게 세고 있어 부풀려진다).
--   그래서 (사람, 루틴, 책)마다 **늘어난 만큼**만 더한다: 이번 쪽수 − 그때까지 가장 멀리 읽은 쪽 (0 보다 작으면 0).
--   책은 띄어쓰기·문장부호를 걷은 제목으로 묶는다 (앱의 loose 와 같은 방식).
--
-- 【하루 상한】 한 번의 인증에서 늘어난 쪽이 300쪽을 넘으면 300쪽까지만 센다. 9999 같은 장난·실수가 합계를 망치지 않게.
--   첫 인증은 0쪽부터 센다 (앱이 「0~N쪽 읽었어요」라고 보여 주는 것과 같다).
--
-- 【언제부터 세나】 dokseo_settings.pages_count_from 날짜 이후의 인증만 합계에 넣는다. 비워 두면 전부 센다.
--   공식 시작일이 정해지면 한 줄로 넣는다:  UPDATE dokseo_settings SET pages_count_from = '2026-11-01' WHERE id = 1;
--   (그 이전 인증에서 읽은 부분은 빠지지만, 그날 이후에 이어 읽은 것은 늘어난 만큼만 센다)
--
-- 【누구나 합계를 볼 수 있다】 전체 합계는 숫자 하나라 로그인 전에도 부를 수 있다 (랜딩페이지가 쓸 수도 있다).
--   「내 쪽수」는 로그인했을 때만 채워지고, 남의 쪽수는 이 함수로 알 수 없다.
--
-- ⚠️ 별도 선행 마이그레이션은 없다 (certifications · dokseo_settings 만 있으면 된다).

ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS pages_count_from date;
COMMENT ON COLUMN dokseo_settings.pages_count_from IS '누적 쪽수를 세기 시작하는 날. 비우면 전부 센다';

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
  ), inc AS (
    -- 그때까지 가장 멀리 읽은 쪽보다 늘어난 만큼 (상한 300). 날짜 조건은 합칠 때 건다 —
    -- 시작일 전에 읽은 부분까지 첫 인증으로 세지 않도록 늘어난 양은 전체 기록으로 구한다
    SELECT user_id, cert_date,
           LEAST(300, GREATEST(0, page_end - COALESCE(
             MAX(page_end) OVER (PARTITION BY user_id, routine_id, bk
                                 ORDER BY cert_date, created_at, id
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0))) AS n
      FROM base
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
-- 알림을 보내지 않는다. SQL 편집기에서는 로그인한 사람이 없어 mine 은 비어 있는 게 맞다 (null).
-- 기대: 칸 1, 함수 1, 합계 total 에 숫자가 나온다
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'dokseo_settings' AND column_name = 'pages_count_from') AS 칸_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_pages_summary')         AS 함수_1이어야,
       dokseo_pages_summary()                                                         AS 합계,
       (SELECT count(*) FROM certifications WHERE page_end IS NOT NULL)               AS 쪽수_있는_인증;
