-- 한끗독서 마이그레이션 85
-- 책방이 직접 비용을 청구한다
--
-- 【지금까지】 아이가 네 자리를 누르면 「정산 대기」 건이 하나 생기고,
--   운영진이 영수증을 따로 받아 금액을 손으로 넣었다. 영수증이 전화·문자로
--   흩어져 들어와서, 어느 건의 영수증인지 매번 맞춰봐야 했다.
--
-- 【바뀌는 것】 그 건에 **책방이 직접** 금액·영수증·교환 사진을 붙인다.
--   운영진은 받아 챙기는 일이 없어지고, 확인하고 정산만 한다.
--
-- 【확정은 여전히 운영진이 한다】 책방이 적어낸 금액은 **청구**지 확정이 아니다.
--   책방 화면에서 바로 돈이 나가게 하면 오타 하나가 그대로 입금된다.
--   한도(2만원) 검사도 settle_book_purchase 에 그대로 남는다.
--
-- 【로그인을 만들지 않는다】 사장님께 계정을 하나 더 드리면 잊어버리신다.
--   책방마다 긴 열쇠가 든 주소를 하나씩 드리고 북마크하시게 한다.
--   그 열쇠로는 **그 책방 건만** 보이고 손댈 수 있다. 새면 다시 발급한다.
--
-- ⚠️ 73(bookstore_codes) · 72(settle_book_purchase) 뒤에 돌린다.

-- ── 1. 책방마다 주소 열쇠 ──────────────────────────────
-- bookstore_codes(네 자리)와 다른 것이다. 저쪽은 아이 폰에 누르는 번호,
-- 이쪽은 사장님이 여는 주소. 섞이면 안 되므로 표를 따로 둔다
CREATE TABLE IF NOT EXISTS bookstore_keys (
  bookstore_id bigint PRIMARY KEY REFERENCES bookstores(id) ON DELETE CASCADE,
  access_key   text   NOT NULL UNIQUE,
  issued_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE bookstore_keys ENABLE ROW LEVEL SECURITY;
-- 아무에게도 직접 읽히지 않는다. 운영진도 아래 함수로만 본다
DROP POLICY IF EXISTS bk_none ON bookstore_keys;

-- ── 2. 책방이 적어낸 것을 담을 칸 ──────────────────────
-- amount(확정)와 따로 둔다. 운영진이 확정하기 전까지 둘이 다를 수 있고,
-- 「책방은 18,000 이라는데 영수증은 16,500」 같은 일이 보여야 한다
ALTER TABLE book_purchases
  ADD COLUMN IF NOT EXISTS store_amount       int,
  ADD COLUMN IF NOT EXISTS store_receipt_path text,
  ADD COLUMN IF NOT EXISTS store_photo_path   text,
  ADD COLUMN IF NOT EXISTS store_note         text,
  ADD COLUMN IF NOT EXISTS store_submitted_at timestamptz;

COMMENT ON COLUMN book_purchases.store_amount       IS '책방이 적어낸 청구 금액. 확정은 amount';
COMMENT ON COLUMN book_purchases.store_receipt_path IS 'store-proofs 버킷 안 영수증 경로';
COMMENT ON COLUMN book_purchases.store_photo_path   IS 'store-proofs 버킷 안 교환 사진 경로';

-- ── 3. 열쇠로 책방을 찾는다 (안에서만 쓴다) ────────────
CREATE OR REPLACE FUNCTION store_of_key(p_key text) RETURNS bigint AS $$
  SELECT bookstore_id FROM bookstore_keys
   WHERE access_key = p_key AND length(coalesce(p_key, '')) >= 24;
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION store_of_key(text) FROM PUBLIC, anon, authenticated;

-- ── 4. 우리 책방에 온 건들 ─────────────────────────────
-- 아이 이름은 닉네임만. 사장님이 알아야 하는 건 「누가 왔나」가 아니라
-- 「이 건이 그 아이 건이 맞나」뿐이다
CREATE OR REPLACE FUNCTION store_pending(p_key text)
RETURNS TABLE (
  id bigint, who text, book_title text, came_at timestamptz,
  store_amount int, submitted boolean, settled boolean
) AS $$
DECLARE v_store bigint;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  RETURN QUERY
  SELECT g.id,
         COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '이름 없음'),
         g.book_title,
         g.created_at,
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

-- ── 5. 청구 올리기 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION store_submit(
  p_key         text,
  p_purchase_id bigint,
  p_amount      int,
  p_receipt     text DEFAULT NULL,
  p_photo       text DEFAULT NULL,
  p_note        text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE v_store bigint; v_row book_purchases;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  SELECT * INTO v_row FROM book_purchases
   WHERE id = p_purchase_id AND bookstore_id = v_store FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '우리 책방 건이 아니에요'; END IF;

  -- 이미 정산이 끝났으면 손대지 않는다. 돈이 나간 기록이다
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION '이미 처리가 끝난 건이에요';
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION '금액을 적어주세요';
  END IF;
  -- 한도는 운영진 확정에서도 한 번 더 본다. 여기서 먼저 알려주면
  -- 사장님이 그 자리에서 알아차린다
  IF p_amount > COALESCE((SELECT voucher_max_amount FROM dokseo_settings WHERE id = 1), 20000) THEN
    RAISE EXCEPTION '한 권에 쓸 수 있는 금액을 넘어요 (최대 %원)',
      to_char(COALESCE((SELECT voucher_max_amount FROM dokseo_settings WHERE id = 1), 20000), 'FM999,999');
  END IF;

  UPDATE book_purchases
     SET store_amount       = p_amount,
         store_receipt_path = COALESCE(p_receipt, store_receipt_path),
         store_photo_path   = COALESCE(p_photo,   store_photo_path),
         store_note         = NULLIF(btrim(COALESCE(p_note, '')), ''),
         store_submitted_at = now()
   WHERE id = p_purchase_id;

  -- 운영진에게 알린다. 올려 두고 아무도 모르면 입금이 늦어진다
  BEGIN
    PERFORM notify_push(a, '책방이 비용을 청구했어요 🧾',
      (SELECT name FROM bookstores WHERE id = v_store) || ' · ' ||
      to_char(p_amount, 'FM999,999') || '원 · 확인해 주세요',
      '/youthit-book/admin.html')
    FROM admin_user_ids() a;
  EXCEPTION WHEN OTHERS THEN NULL;   -- 알림이 터져도 청구는 들어간다
  END;

  RETURN jsonb_build_object('ok', true, 'id', p_purchase_id, 'amount', p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_submit(text, bigint, int, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_submit(text, bigint, int, text, text, text) TO anon, authenticated;

-- ── 6. 운영진이 열쇠를 내준다 ──────────────────────────
-- 없으면 만들고, 있으면 그대로 돌려준다. 다시 발급하려면 p_reissue
CREATE OR REPLACE FUNCTION store_key(p_bookstore_id bigint, p_reissue boolean DEFAULT false)
RETURNS text AS $$
DECLARE v_key text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  IF p_reissue THEN DELETE FROM bookstore_keys WHERE bookstore_id = p_bookstore_id; END IF;

  SELECT access_key INTO v_key FROM bookstore_keys WHERE bookstore_id = p_bookstore_id;
  IF v_key IS NOT NULL THEN RETURN v_key; END IF;

  -- 32자. 주소에 그대로 실리므로 /+= 가 없는 글자만 쓴다
  v_key := replace(replace(replace(encode(gen_random_bytes(24), 'base64'), '/', 'A'), '+', 'B'), '=', '');
  INSERT INTO bookstore_keys(bookstore_id, access_key) VALUES (p_bookstore_id, v_key);
  RETURN v_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_key(bigint, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION store_key(bigint, boolean) TO authenticated;

-- ── 7. 사장님이 올린 파일이 들어갈 자리 ────────────────
-- 비공개 버킷이다. 넣기만 되고, 읽기는 운영진만.
-- ⚠️ 로그인 없는 화면에서 올리므로 **넣기는 anon 에게 열려 있다.**
--    버킷 이름을 알면 쓰레기 파일을 넣을 수는 있다(읽지는 못한다).
--    파트너 일곱 곳 규모에서는 이 정도로 두고, 커지면 Edge Function 으로
--    열쇠를 검사한 뒤 올리도록 좁힌다 (book-search 와 같은 모양)
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('store-proofs', 'store-proofs', false, 10485760)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS store_proofs_insert ON storage.objects;
CREATE POLICY store_proofs_insert ON storage.objects FOR INSERT TO anon, authenticated
  WITH CHECK (bucket_id = 'store-proofs');

DROP POLICY IF EXISTS store_proofs_read ON storage.objects;
CREATE POLICY store_proofs_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'store-proofs' AND is_admin());

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'store_pending')        AS 목록함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_submit')         AS 청구함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_key')            AS 열쇠함수,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'book_purchases' AND column_name = 'store_amount') AS 청구금액칸,
       (SELECT count(*) FROM bookstores WHERE active)                        AS 열쇠줄_책방;
