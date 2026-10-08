-- 한끗독서 마이그레이션 97
-- 책 교환 인증 카드에 책방 이름을 더한다
--
-- 【왜】 카드를 「사진 + 책방 이름」으로 보이고, 눌렀을 때 닉네임·이유가 나오게 바꾼다.
--   책방 이름은 이미 누구나 읽는 bookstores 의 것이라 새로 열리는 정보는 아니다.
--   다만 **어느 아이가 어느 책방에서 받았는지**가 한 줄로 묶이므로 로그인한 사람에게만 낸다.
-- 반환 칸이 바뀌어서 지우고 다시 만든다 (CREATE OR REPLACE 로는 반환 모양을 못 바꾼다).
-- ⚠️ 96 뒤에 돌린다.

DROP FUNCTION IF EXISTS exchange_feed(int);

CREATE OR REPLACE FUNCTION exchange_feed(p_limit int DEFAULT 30)
RETURNS TABLE (id bigint, photo_url text, reason text, nick text, day date, store_name text) AS $$
  SELECT b.id,
         COALESCE(NULLIF(btrim(b.book_photo_url), ''),
                  CASE WHEN b.proof_photo_url LIKE 'http%' THEN b.proof_photo_url END),
         NULLIF(btrim(COALESCE(b.pick_reason, '')), ''),
         COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '익명'),
         (b.created_at AT TIME ZONE 'Asia/Seoul')::date,
         s.name
    FROM book_purchases b
    LEFT JOIN profiles   p ON p.id = b.user_id
    LEFT JOIN bookstores s ON s.id = b.bookstore_id
   WHERE b.photo_public
     AND b.status <> 'void'
     AND COALESCE(NULLIF(btrim(b.book_photo_url), ''),
                  CASE WHEN b.proof_photo_url LIKE 'http%' THEN b.proof_photo_url END) IS NOT NULL
   ORDER BY b.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 60)
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION exchange_feed(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION exchange_feed(int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 함수를 실제로 불러 본다 (새 칸 store_name 까지 읽는다). 아직 공개 건이 없으면 0
SELECT (SELECT count(*) FROM exchange_feed(60))                                   AS 지금_보이는_인증,
       (SELECT count(*) FROM exchange_feed(60) WHERE store_name IS NOT NULL)      AS 책방이름_붙은_것;
