-- 한끗독서 마이그레이션 90
-- ① 사장님이 바쁠 때 — 사진만 찍고 금액은 나중에
-- ② 아이가 받은 날 남기는 한 줄 — 「왜 이 책을 골랐어요?」
--
-- 【① 왜 필요한가】 QR 을 찍었는데 손님이 밀려 금액·영수증을 못 올리면,
--   15분 뒤 쪽지가 사라지고 **아이는 이미 가버린** 뒤다. 책은 나갔는데
--   기록이 없다. 스캔한 순간을 「받았다」로 못박고 금액은 나중에 받는다.
--   그 뒤는 지금 있는 목록 화면(store.html?k=)에서 올리면 된다.
--
--   ⚠️ **사진만은 미룰 수 없다.** 아이가 가고 나면 못 찍는다. 그래서
--      「나중에」 쪽에서도 사진은 그 자리에서 받는다 — 다만 **막지는 않는다.**
--      정말 바쁜 순간이 있고, 거기서 막으면 사장님이 창을 닫아 버린다.
--      그때는 아이가 올린 사진과 영수증으로 운영진이 맞춘다.
--
-- 【② 왜 「후기」가 아닌가】 받은 그 자리에서는 아직 안 읽었다. 「어땠어?」를
--   물으면 쓸 말이 없다. 「왜 골랐어요?」는 그날 가장 쓰기 쉬운 말이고,
--   다 읽고 쓰는 책인증후기(+30P)는 그대로 남는다. 한 책에 **고를 때의 마음**과
--   **읽고 난 마음**이 둘 다 남는다.
--
-- ⚠️ 88·89 뒤에 돌린다.

-- ── 1. 고른 이유를 담을 칸 ─────────────────────────────
ALTER TABLE book_purchases
  ADD COLUMN IF NOT EXISTS pick_reason text;
COMMENT ON COLUMN book_purchases.pick_reason IS '받은 날 아이가 적은 「왜 이 책을 골랐나」';

-- ── 2. 사진만 찍고 나중에 ──────────────────────────────
-- 금액 없이 교환만 못박는다. store_submitted_at 은 비워 둔다 —
-- 그래야 사장님 목록에 「아직 안 보냈어요」로 남고, 운영진 쪽에도 「책방 대기」로 뜬다
CREATE OR REPLACE FUNCTION redeem_qr_hold(
  p_token text,
  p_code  text,
  p_photo text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE r redemptions; v_pid bigint; v_store text; a uuid;
BEGIN
  SELECT * INTO r FROM redemptions WHERE token = p_token FOR UPDATE;
  IF NOT FOUND             THEN RAISE EXCEPTION '쪽지를 찾지 못했어요'; END IF;
  IF r.status = 'done'     THEN RAISE EXCEPTION '이미 끝난 교환이에요'; END IF;
  IF r.status <> 'issued'  THEN RAISE EXCEPTION '쓸 수 없는 쪽지예요'; END IF;
  IF r.expires_at <= now() THEN RAISE EXCEPTION '시간이 지났어요. 청소년에게 다시 띄워달라고 해주세요'; END IF;

  IF NOT EXISTS (SELECT 1 FROM bookstore_codes c
                  WHERE c.bookstore_id = r.bookstore_id AND btrim(c.code) = btrim(p_code)) THEN
    RAISE EXCEPTION '확인 번호가 달라요';
  END IF;

  INSERT INTO book_purchases(user_id, routine_id, bookstore_id, code_ok, store_photo_path)
  VALUES (r.user_id, r.routine_id, r.bookstore_id, true, p_photo)
  RETURNING id INTO v_pid;

  UPDATE redemptions SET status = 'done', purchase_id = v_pid, done_at = now() WHERE id = r.id;

  SELECT name INTO v_store FROM bookstores WHERE id = r.bookstore_id;
  BEGIN
    PERFORM notify_push(r.user_id, '책을 받았어요 📚',
      v_store || ' · 받은 책을 한 장 남겨주세요', '/youthit-book/app.html?tab=my');
    FOR a IN SELECT * FROM admin_user_ids() LOOP
      PERFORM notify_push(a, '교환이 있었어요 📗',
        v_store || ' · 금액은 책방이 나중에 올려요', '/youthit-book/admin.html');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'purchase_id', v_pid, 'held', true);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_qr_hold(text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION redeem_qr_hold(text, text, text) TO anon, authenticated;

-- ── 3. 아이 사진 + 고른 이유 ───────────────────────────
CREATE OR REPLACE FUNCTION redeem_add_photo(
  p_purchase_id bigint,
  p_proof       text,
  p_public      boolean DEFAULT true,
  p_reason      text    DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE v_u uuid := auth.uid(); n int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  IF COALESCE(btrim(p_proof), '') = '' THEN RAISE EXCEPTION '사진을 골라주세요'; END IF;

  UPDATE book_purchases
     SET proof_photo_url = p_proof,
         photo_public    = COALESCE(p_public, true),
         pick_reason     = NULLIF(btrim(COALESCE(p_reason, '')), '')
   WHERE id = p_purchase_id
     AND user_id = v_u
     AND status <> 'void'
     AND COALESCE(proof_photo_url, '') = '';   -- 한 번 올리면 끝이다
  GET DIAGNOSTICS n = ROW_COUNT;

  IF n = 0 THEN RAISE EXCEPTION '사진을 올릴 수 없는 건이에요'; END IF;
  RETURN jsonb_build_object('ok', true, 'id', p_purchase_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 89 에서 만든 세 칸짜리는 지운다. 남겨 두면 어느 쪽이 불리는지 알 수 없다
DROP FUNCTION IF EXISTS redeem_add_photo(bigint, text, boolean);

REVOKE EXECUTE ON FUNCTION redeem_add_photo(bigint, text, boolean, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION redeem_add_photo(bigint, text, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'redeem_qr_hold')    AS 나중에함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'redeem_add_photo')  AS 사진함수_하나여야,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'book_purchases' AND column_name = 'pick_reason') AS 고른이유칸;
