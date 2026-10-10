-- 한끗독서 마이그레이션 111
-- 책방지기의 추천 책에 표지를 단다
--
-- 【왜】 홈에서 책방 추천을 책 표지로 보여 준다. 사장님이 책을 검색해서 고르면 그 표지를 함께 저장한다.
--   검색 없이 제목만 적으면 표지는 비어 있고, 앱이 제목으로 찾아 보여 준다.
--
-- 【사장님 화면의 책 검색】 사장님은 로그인한 회원이 아니라 책방 열쇠로 들어온다. 책 검색 함수(book-search)는
--   회원만 통과시키므로, 「책방 열쇠가 맞는가」를 묻는 store_key_ok 를 만들고 함수가 그걸로도 통과시킨다.
--   (함수 쪽은 supabase/functions/book-search/index.ts 를 다시 배포해야 한다)
--
-- 【표지 주소 검사】 https 로 시작하고 500자 이하일 때만 저장한다. 아니면 비운다.
--
-- ⚠️ 85(store_of_key) · 110 뒤에 돌린다. 110 의 두 함수는 인자가 바뀌어 지우고 다시 만든다.

ALTER TABLE bookstores ADD COLUMN IF NOT EXISTS pick_cover text;
COMMENT ON COLUMN bookstores.pick_cover IS '추천 책 표지 주소 (책 검색에서 고른 것)';

-- 책방 열쇠가 맞는가. 책 검색 함수가 부른다 (열쇠 자체는 돌려주지 않는다)
CREATE OR REPLACE FUNCTION store_key_ok(p_key text) RETURNS boolean AS $$
  SELECT store_of_key(p_key) IS NOT NULL
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION store_key_ok(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_key_ok(text) TO anon, authenticated;

DROP FUNCTION IF EXISTS store_pick(text);
CREATE OR REPLACE FUNCTION store_pick(p_key text)
RETURNS TABLE (pick_title text, pick_line text, pick_cover text) AS $$
DECLARE v_store bigint;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;
  RETURN QUERY SELECT b.pick_title, b.pick_line, b.pick_cover FROM bookstores b WHERE b.id = v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION store_pick(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_pick(text) TO anon, authenticated;

DROP FUNCTION IF EXISTS store_set_pick(text, text, text);
CREATE OR REPLACE FUNCTION store_set_pick(p_key text, p_title text, p_line text, p_cover text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_store bigint; v_t text; v_l text; v_c text;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  v_t := NULLIF(left(btrim(COALESCE(p_title, '')), 60), '');
  v_l := NULLIF(left(btrim(COALESCE(p_line,  '')), 80), '');
  IF v_l IS NOT NULL AND v_t IS NULL THEN RAISE EXCEPTION '책 제목도 적어 주세요'; END IF;
  -- 표지는 책이 있을 때, https 주소일 때만
  v_c := CASE WHEN v_t IS NOT NULL AND p_cover ~ '^https://' AND char_length(p_cover) <= 500 THEN p_cover ELSE NULL END;

  UPDATE bookstores SET pick_title = v_t, pick_line = v_l, pick_cover = v_c,
                        pick_at = CASE WHEN v_t IS NULL THEN NULL ELSE now() END
   WHERE id = v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_set_pick(text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_set_pick(text, text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 칸 1, 함수 셋 모두 1
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'bookstores' AND column_name = 'pick_cover') AS 칸_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_key_ok')     AS 열쇠함수_1,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_pick')       AS 읽기함수_1,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_set_pick')   AS 쓰기함수_1;
