-- 한끗독서 마이그레이션 149
-- 책방 안내문(store-guide.html)에 서점 주소를 함께 보여 준다
--
-- store_card 가 돌려주는 칸에 address 를 더한다. 칸이 바뀌는 함수라
-- CREATE OR REPLACE 로는 안 되고 한 번 지우고 다시 만든다.
-- 안내문은 address 가 비어 있거나 이 마이그레이션이 아직이면 지역(region)으로 대신 보여 준다.
--
-- ⚠️ 87 뒤에 돌린다. 여러 번 돌려도 된다.

DROP FUNCTION IF EXISTS store_card(text);

CREATE FUNCTION store_card(p_key text)
RETURNS TABLE (name text, region text, code text, phone text, address text) AS $$
DECLARE v_store bigint;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  RETURN QUERY
  -- ⚠️ bookstore_codes.code 는 character(4) 다. text 로 캐스팅해서 돌려준다 (87)
  SELECT b.name, b.region, btrim(c.code)::text, b.phone, b.address
    FROM bookstores b
    LEFT JOIN bookstore_codes c ON c.bookstore_id = b.id
   WHERE b.id = v_store;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION store_card(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_card(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 주소 칸이 생겼는지, 첫 책방이 그대로 불러지는지
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'store_card' AND pg_get_function_result(oid) LIKE '%address%') AS 새판_1이어야,
       (SELECT name FROM store_card((SELECT access_key FROM bookstore_keys LIMIT 1))) AS 첫_책방,
       (SELECT address FROM store_card((SELECT access_key FROM bookstore_keys LIMIT 1))) AS 그_책방_주소;
