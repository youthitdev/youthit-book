-- 한끗독서 마이그레이션 177
-- 앱 「후기」 탭을 로그인 없이도 볼 수 있게 한다 (2026-11-19 사용자: 「모든 후기 글은 로그인 하지 않아도 모두가 볼 수 있도록」)
--
-- 【배경】 지금까지 모임 후기는 「같은 모임 친구들」만 읽을 수 있었다 (reviews RLS: visible_routine_ids).
--   문장·후기의 「공개」(is_public / quote_public)는 홈페이지·후원자 화면 전용이었고 앱 후기 탭과는 별개였다.
--
-- 【하는 일】 로그인 없이(anon)도 부를 수 있는 읽기 함수 둘을 만든다. 표 자체의 읽기 규칙(RLS)은 바꾸지 않는다.
--   · public_reviews(개수)  — 모임 후기 전부. 책 후기(kind='book')는 후기 탭에서 가려 둔 그대로 뺀다.
--       글쓴이 이름·닉네임·번호는 **주지 않는다** (글, 모임 이름, 날짜만). 탈퇴한 회원의 글, 매일 한끗 글은 뺀다.
--       운영진이 「밖에서 가리기」를 켠 글(hide_public)도 뺀다.
--   · public_quotes(개수)   — 문장은 운영진이 「공개」로 고른 것(quote_public)만. 닉네임 없음. 끗짱 글·매일 한끗·탈퇴 회원은 뺀다.
--   · reviews.hide_public 칸 — 글에 개인 이야기·실명이 들어 있을 때 운영진이 밖에서만 가린다 (같은 모임 친구들에게는 그대로 보임).
--
-- 되돌리려면: DROP FUNCTION public_reviews(int); DROP FUNCTION public_quotes(int);  (hide_public 칸은 두어도 된다)
-- ⚠️ 여러 번 돌려도 된다.

ALTER TABLE reviews ADD COLUMN IF NOT EXISTS hide_public boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public_reviews(p_limit int DEFAULT 60)
RETURNS TABLE (id bigint, content text, routine_title text, created_at timestamptz) AS $$
  SELECT r.id, r.content, ro.title, r.created_at
    FROM reviews r
    JOIN routines ro ON ro.id = r.routine_id
    JOIN profiles p  ON p.id  = r.user_id
   WHERE r.kind = 'routine'
     AND NOT r.hide_public
     AND btrim(COALESCE(r.content, '')) <> ''
     AND p.withdrawn_at IS NULL
     AND NOT COALESCE(ro.ongoing, false)
   ORDER BY r.created_at DESC, r.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 60), 1), 200)
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION public_reviews(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public_reviews(int) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public_quotes(p_limit int DEFAULT 60)
RETURNS TABLE (id bigint, quote text, book_title text, created_at timestamptz) AS $$
  SELECT c.id, c.quote, c.book_title, c.created_at
    FROM certifications c
    JOIN routines ro ON ro.id = c.routine_id
    JOIN profiles p  ON p.id  = c.user_id
   WHERE c.quote_public
     AND btrim(COALESCE(c.quote, '')) <> ''
     AND p.withdrawn_at IS NULL
     AND NOT COALESCE(p.can_lead, false)
     AND NOT COALESCE(ro.ongoing, false)
   ORDER BY c.created_at DESC, c.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 60), 1), 200)
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION public_quotes(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public_quotes(int) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 칸 1 / 함수 2 / 익명호출 둘 다 true / 지금 공개되는 후기·문장 수
SELECT (SELECT count(*) FROM information_schema.columns WHERE table_name = 'reviews' AND column_name = 'hide_public') AS 칸_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname IN ('public_reviews', 'public_quotes'))                            AS 함수_2여야,
       has_function_privilege('anon', 'public_reviews(int)', 'EXECUTE')
         AND has_function_privilege('anon', 'public_quotes(int)', 'EXECUTE')                                          AS 익명호출_true여야,
       (SELECT count(*) FROM public_reviews(200))                                                                     AS 공개되는_후기,
       (SELECT count(*) FROM public_quotes(200))                                                                      AS 공개되는_문장;
