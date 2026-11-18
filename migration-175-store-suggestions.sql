-- 한끗독서 마이그레이션 175
-- 책방이 없는 동네의 청소년이 「알고 있는 동네 책방」을 추천한다 (2026-11-18 QA 제안 → 사용자 「A로 하자」)
--
-- 【하는 일】
--   1. store_suggestions 표: 누가 · 어느 동네에서 · 어느 책방을 추천했는지 + 한 줄 이유(선택) + 운영진 「연락했어요」 표시.
--      청소년은 자기 추천만 읽고 지울 수 있다. 쓰기는 아래 함수로만. 운영진은 전부 읽고, 표시·삭제를 한다.
--   2. suggest_store(책방 이름, 한 줄 이유) — 내 사는 동네(시·도 + 시·군·구)로 한 줄을 넣는다.
--      · 한 사람이 최대 3곳 · 같은 책방은 한 번만 (「OO책방」과 「OO」, 띄어쓰기·대소문자 차이는 같은 책방으로 본다)
--      · 이미 함께하는(운영 중인) 책방 이름이면 막는다
--      · 사는 곳을 안 적었으면 막는다
-- 되돌리려면: DROP FUNCTION suggest_store(text, text); DROP TABLE store_suggestions;
-- ⚠️ 여러 번 돌려도 된다.

-- 「OO책방」·「OO 서점」·「oo」를 같은 이름으로 맞춘다 (띄어쓰기 제거 · 소문자 · 끝의 책방/서점 제거)
CREATE OR REPLACE FUNCTION store_name_key(n text) RETURNS text AS $$
  SELECT regexp_replace(lower(regexp_replace(btrim(COALESCE(n, '')), '\s+', '', 'g')), '(책방|서점)$', '')
$$ LANGUAGE sql IMMUTABLE;

CREATE TABLE IF NOT EXISTS store_suggestions (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id    uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  region     text NOT NULL,
  store_name text NOT NULL,
  name_key   text NOT NULL,
  note       text,
  handled    boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS store_suggestions_user_name_uq ON store_suggestions (user_id, name_key);
CREATE INDEX IF NOT EXISTS store_suggestions_region_idx ON store_suggestions (region);

ALTER TABLE store_suggestions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS store_suggestions_own_read ON store_suggestions;
CREATE POLICY store_suggestions_own_read ON store_suggestions FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin());

DROP POLICY IF EXISTS store_suggestions_own_delete ON store_suggestions;
CREATE POLICY store_suggestions_own_delete ON store_suggestions FOR DELETE TO authenticated
  USING (user_id = auth.uid() OR is_admin());

DROP POLICY IF EXISTS store_suggestions_admin_update ON store_suggestions;
CREATE POLICY store_suggestions_admin_update ON store_suggestions FOR UPDATE TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

CREATE OR REPLACE FUNCTION suggest_store(p_name text, p_note text DEFAULT NULL) RETURNS jsonb AS $$
DECLARE
  v_u uuid := auth.uid(); v_region text; v_name text; v_key text; v_note text; v_id bigint;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  v_name := regexp_replace(btrim(COALESCE(p_name, '')), '\s+', ' ', 'g');
  v_key  := store_name_key(v_name);
  v_note := NULLIF(btrim(COALESCE(p_note, '')), '');
  IF v_key = '' THEN RAISE EXCEPTION '책방 이름을 적어 주세요'; END IF;
  IF char_length(v_name) > 30 THEN RAISE EXCEPTION '책방 이름은 30자까지 적을 수 있어요'; END IF;
  IF v_note IS NOT NULL AND char_length(v_note) > 60 THEN RAISE EXCEPTION '한 줄 이유는 60자까지 적을 수 있어요'; END IF;

  SELECT regexp_replace(btrim(COALESCE(region, '')), '\s+', ' ', 'g') INTO v_region FROM profiles WHERE id = v_u;
  IF v_region IS NULL OR v_region !~ '^\S+ \S+' THEN
    RAISE EXCEPTION '사는 곳을 먼저 적어 주세요 (MY → 프로필)';
  END IF;

  IF EXISTS (SELECT 1 FROM bookstores b WHERE b.active AND store_name_key(b.name) = v_key) THEN
    RAISE EXCEPTION '이미 한끗독서와 함께하는 책방이에요';
  END IF;
  IF EXISTS (SELECT 1 FROM store_suggestions WHERE user_id = v_u AND name_key = v_key) THEN
    RAISE EXCEPTION '이미 추천한 책방이에요';
  END IF;
  IF (SELECT count(*) FROM store_suggestions WHERE user_id = v_u) >= 3 THEN
    RAISE EXCEPTION '추천은 최대 3곳까지 할 수 있어요. 하나를 지우고 다시 해 주세요';
  END IF;

  INSERT INTO store_suggestions (user_id, region, store_name, name_key, note)
  VALUES (v_u, v_region, v_name, v_key, v_note)
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION suggest_store(text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION suggest_store(text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 표 1 / 표 정책 3 / 함수 1 / 로그인 없는 사람에게는 닫혀 있음 true
SELECT (SELECT count(*) FROM pg_tables WHERE tablename = 'store_suggestions')                      AS 표_1이어야,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'store_suggestions')                    AS 표정책_3이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'suggest_store')                              AS 함수_1이어야,
       NOT has_function_privilege('anon', 'suggest_store(text, text)', 'EXECUTE')                  AS 익명_차단_true여야;
