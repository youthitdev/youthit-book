-- 한끗독서 마이그레이션 178
-- 앱 「후기」 탭의 문장도 전부 공개 (2026-11-19 사용자: 「전부 공개해줘」) + 후기 「밖에서 가리기」를 청소년이 못 풀게 막기
--
-- 【하는 일】
--   1. public_quotes — 177 은 운영진이 「공개」로 고른 문장만 줬다. 이제 **문장이 있는 인증 전부**를 준다.
--      (닉네임 없음 · 끗짱 글·매일 한끗(나만 보는 모임)·탈퇴 회원은 그대로 뺀다. 「공개」(quote_public)는 홈페이지·후원자용으로 따로 남는다.)
--   2. quote_hidden 표 — 운영진이 개인 이야기·실명이 든 문장을 「밖에서 가리기」 하면 여기에 들어가고, public_quotes 가 뺀다.
--      청소년은 읽지도 쓰지도 못한다 (운영진만). 같은 모임 친구들에게는 그대로 보인다.
--   3. reviews.hide_public 보호 — 177 에서 만든 칸을 청소년이 직접 바꿔 가리기를 풀 수 없게, 운영진이 아니면 값을 그대로 둔다.
--
-- 되돌리려면: 177 의 public_quotes 정의를 다시 돌린다 (공개로 고른 문장만).
-- ⚠️ 177 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS quote_hidden (
  cert_id    bigint PRIMARY KEY REFERENCES certifications(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE quote_hidden ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS quote_hidden_admin ON quote_hidden;
CREATE POLICY quote_hidden_admin ON quote_hidden FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

CREATE OR REPLACE FUNCTION public_quotes(p_limit int DEFAULT 60)
RETURNS TABLE (id bigint, quote text, book_title text, created_at timestamptz) AS $$
  SELECT c.id, c.quote, c.book_title, c.created_at
    FROM certifications c
    JOIN routines ro ON ro.id = c.routine_id
    JOIN profiles p  ON p.id  = c.user_id
   WHERE btrim(COALESCE(c.quote, '')) <> ''
     AND NOT EXISTS (SELECT 1 FROM quote_hidden h WHERE h.cert_id = c.id)
     AND p.withdrawn_at IS NULL
     AND NOT COALESCE(p.can_lead, false)
     AND NOT COALESCE(ro.ongoing, false)
   ORDER BY c.created_at DESC, c.id DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 60), 1), 200)
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION public_quotes(int) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public_quotes(int) TO anon, authenticated;

-- 청소년이 자기 후기의 hide_public 을 바꾸지 못하게 한다 (운영진이 가린 글을 직접 풀거나, 새 글에 미리 넣는 것 모두)
CREATE OR REPLACE FUNCTION keep_review_hide_public() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'INSERT' THEN NEW.hide_public := false;
  ELSE NEW.hide_public := OLD.hide_public; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
DROP TRIGGER IF EXISTS reviews_keep_hide_public ON reviews;
CREATE TRIGGER reviews_keep_hide_public BEFORE INSERT OR UPDATE ON reviews
  FOR EACH ROW EXECUTE FUNCTION keep_review_hide_public();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 표 1 / 트리거 1 / 익명호출 true / 지금 공개되는 문장 수 (177 때의 0 보다 커진다)
SELECT (SELECT count(*) FROM pg_tables WHERE tablename = 'quote_hidden')                                AS 표_1이어야,
       (SELECT count(*) FROM pg_trigger WHERE tgname = 'reviews_keep_hide_public' AND NOT tgisinternal) AS 트리거_1이어야,
       has_function_privilege('anon', 'public_quotes(int)', 'EXECUTE')                                  AS 익명호출_true여야,
       (SELECT count(*) FROM public_quotes(200))                                                        AS 공개되는_문장;
