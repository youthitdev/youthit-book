-- 한끗독서 마이그레이션 86
-- 85 의 store_pending 을 고친다 — 없는 칸을 읽고 있었다
--
-- 【무엇이 틀렸나】 `book_purchases.book_title` 을 읽었는데 그런 칸이 없다.
--   교환하는 시점에는 책 제목을 받지 않는다 — 제목은 나중에 책인증후기를
--   쓸 때(`reviews.book_title`) 들어온다.
--   PostgreSQL 은 함수를 만들 때 안쪽 칸을 검사하지 않아서, 85 는 「Success」로
--   끝나고 **부를 때서야** 42703 으로 터졌다.
--
-- 【대신 무엇을 보여주나】 아무것도 안 보여준다.
--   사장님이 그 건을 알아보는 기준은 **닉네임과 시각**이면 충분하다. 방금
--   책을 건넨 분이니까. 「참여할 때 고른 책」을 끌어다 쓸 수도 있지만, 그건
--   루틴에서 읽는 책이지 **교환해 간 책이 아니다** — 다른 책을 보여주면
--   사장님이 「내가 준 책이 아닌데?」 하고 멈춘다.
--
-- 【대신 더한 것】 `code_ok` — 그 자리에서 네 자리를 눌렀는지.
--   「번호 없이」로 들어온 건은 사장님도 한 번 더 확인하시는 게 맞다.
--
-- ⚠️ 돌려주는 칸이 바뀌므로 CREATE OR REPLACE 로는 안 된다. 먼저 지운다.

DROP FUNCTION IF EXISTS store_pending(text);

CREATE OR REPLACE FUNCTION store_pending(p_key text)
RETURNS TABLE (
  id bigint, who text, came_at timestamptz,
  code_ok boolean, store_amount int, submitted boolean, settled boolean
) AS $$
DECLARE v_store bigint;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  RETURN QUERY
  SELECT g.id,
         COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '이름 없음'),
         g.created_at,
         COALESCE(g.code_ok, false),
         g.store_amount,
         g.store_submitted_at IS NOT NULL,
         g.status = 'settled'
    FROM book_purchases g
    LEFT JOIN profiles p ON p.id = g.user_id
   WHERE g.bookstore_id = v_store
     AND g.status <> 'void'
     AND g.created_at > now() - interval '60 days'
   ORDER BY g.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION store_pending(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_pending(text) TO anon, authenticated;

-- 새 함수를 API 가 알아보게 깨운다. 85 에서 이 줄을 빠뜨렸다
NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 함수가 **실제로 도는지**까지 본다. 만들어지기만 한 것은 85 에서 이미 겪었다
SELECT count(*) AS 열쇠, (SELECT count(*) FROM store_pending(
         (SELECT access_key FROM bookstore_keys LIMIT 1))) AS 그_책방_건수
  FROM bookstore_keys;
