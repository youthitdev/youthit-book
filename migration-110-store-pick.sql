-- 한끗독서 마이그레이션 110
-- 책방지기의 한 줄 추천
--
-- 【왜】 섭외 페이지에서 책방 사장님의 「다정함」이 이 서비스의 핵심이라고 말했다. 그런데 앱에서 아이가
--   책방을 고를 때 사장님이 보이는 곳이 없었다. 사장님이 「이번 달 이 책 어때요」 한 줄을 남기면, 아이가
--   책방을 고를 때 그 사람의 목소리가 먼저 들린다. 사장님에게는 참여할 이유가 하나 더 생긴다.
--
-- 【무엇을 남기나】 책 제목 하나와 한 줄(80자). 둘 다 비우면 추천이 내려간다.
--
-- 【어디서 쓰나】 사장님 화면(store.html). 로그인한 책방의 열쇠로 자기 책방 것만 고친다 (store_of_key).
--   앱에서는 책방 정보 창에 「사장님 추천」으로 보인다. 운영진은 관리자 화면 서점 표에서 보고 지울 수 있다.
--
-- ⚠️ 85(store_of_key) 뒤에 돌린다.

ALTER TABLE bookstores
  ADD COLUMN IF NOT EXISTS pick_title text,
  ADD COLUMN IF NOT EXISTS pick_line  text,
  ADD COLUMN IF NOT EXISTS pick_at    timestamptz;
COMMENT ON COLUMN bookstores.pick_title IS '책방지기가 추천하는 책 제목';
COMMENT ON COLUMN bookstores.pick_line  IS '책방지기의 추천 한 줄 (80자)';

-- ── 내 책방의 추천을 읽는다 (사장님 화면) ──────────────
CREATE OR REPLACE FUNCTION store_pick(p_key text)
RETURNS TABLE (pick_title text, pick_line text) AS $$
DECLARE v_store bigint;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;
  RETURN QUERY SELECT b.pick_title, b.pick_line FROM bookstores b WHERE b.id = v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION store_pick(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_pick(text) TO anon, authenticated;

-- ── 추천을 남긴다 ──────────────────────────────────────
CREATE OR REPLACE FUNCTION store_set_pick(p_key text, p_title text, p_line text)
RETURNS void AS $$
DECLARE v_store bigint; v_t text; v_l text;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  v_t := NULLIF(left(btrim(COALESCE(p_title, '')), 60), '');
  v_l := NULLIF(left(btrim(COALESCE(p_line,  '')), 80), '');
  -- 책 제목 없이 한 줄만 있으면 무슨 책인지 모른다
  IF v_l IS NOT NULL AND v_t IS NULL THEN RAISE EXCEPTION '책 제목도 적어 주세요'; END IF;

  UPDATE bookstores SET pick_title = v_t, pick_line = v_l,
                        pick_at = CASE WHEN v_t IS NULL THEN NULL ELSE now() END
   WHERE id = v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_set_pick(text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_set_pick(text, text, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 칸 3, 함수 둘 다 1
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'bookstores' AND column_name IN ('pick_title', 'pick_line', 'pick_at')) AS 칸_3이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_pick')     AS 읽기함수_1,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_set_pick') AS 쓰기함수_1;
