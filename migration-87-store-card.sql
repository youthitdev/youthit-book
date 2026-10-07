-- 한끗독서 마이그레이션 87
-- 책방 안내문이 읽을 것 — 책방 이름과 확인 번호
--
-- 사장님께 드릴 종이 한 장(store-guide.html)이 쓴다. 책방마다 다른 것이
-- 둘이라 한 장씩 만들어야 한다 — **확인 번호 네 자리**와 **책방 주소**.
--
-- 【번호를 내주는 게 괜찮은가】 괜찮다. 이 함수는 **그 책방의 열쇠**를 가진
--   사람에게만 답한다. 열쇠를 가진 사람은 곧 그 책방이고, 자기 번호를 보는 것이다.
--   청소년 앱으로는 여전히 안 나간다.
--
-- ⚠️ 85(store_of_key) · 73(bookstore_codes) 뒤에 돌린다.

CREATE OR REPLACE FUNCTION store_card(p_key text)
RETURNS TABLE (name text, region text, code text, phone text) AS $$
DECLARE v_store bigint;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  RETURN QUERY
  SELECT b.name, b.region, c.code, b.phone
    FROM bookstores b
    LEFT JOIN bookstore_codes c ON c.bookstore_id = b.id
   WHERE b.id = v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION store_card(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_card(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 만들어지기만 한 것은 85 에서 이미 당했다. 실제로 불러 본다
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'store_card') AS 함수,
       (SELECT name FROM store_card((SELECT access_key FROM bookstore_keys LIMIT 1))) AS 첫_책방,
       (SELECT code FROM store_card((SELECT access_key FROM bookstore_keys LIMIT 1))) AS 그_책방_번호;
