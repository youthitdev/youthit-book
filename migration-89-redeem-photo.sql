-- 한끗독서 마이그레이션 89
-- 책을 받은 뒤에 아이가 사진을 남긴다
--
-- 【왜 나중인가】 88 에서 순서가 뒤집혔다. 사장님이 QR 을 찍어 확정하는
--   순간 교환은 끝나고, 그때 아이는 아직 사진을 안 찍었다.
--   책을 받아 들고 가게를 나와서, 제 앱에서 한 장 남긴다.
--   사장님 앞에서 사진 찍느라 서 있지 않아도 된다.
--
-- 【왜 함수가 필요한가】 book_purchases 에는 아이가 쓸 수 있는 UPDATE 길이
--   없다. 금액·상태가 같은 표에 있어서 통째로 열면 안 된다.
--   **제 건의, 사진 두 칸만, 아직 비어 있을 때만** 열어 주는 문을 낸다.
--
-- ⚠️ 88 뒤에 돌린다.

CREATE OR REPLACE FUNCTION redeem_add_photo(
  p_purchase_id bigint,
  p_proof       text,
  p_public      boolean DEFAULT true
) RETURNS jsonb AS $$
DECLARE v_u uuid := auth.uid(); n int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  IF COALESCE(btrim(p_proof), '') = '' THEN RAISE EXCEPTION '사진을 골라주세요'; END IF;

  UPDATE book_purchases
     SET proof_photo_url = p_proof,
         photo_public    = COALESCE(p_public, true)
   WHERE id = p_purchase_id
     AND user_id = v_u
     AND status <> 'void'
     -- 한 번 올리면 끝이다. 운영진이 보고 공개한 뒤에 바뀌면 안 된다
     AND COALESCE(proof_photo_url, '') = '';
  GET DIAGNOSTICS n = ROW_COUNT;

  IF n = 0 THEN RAISE EXCEPTION '사진을 올릴 수 없는 건이에요'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_purchase_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION redeem_add_photo(bigint, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION redeem_add_photo(bigint, text, boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'redeem_add_photo')          AS 사진함수,
       (SELECT count(*) FROM book_purchases
         WHERE status <> 'void' AND COALESCE(proof_photo_url, '') = '')           AS 사진없는_건,
       (SELECT count(*) FROM redemptions WHERE status = 'done')                   AS 끝난_교환;
