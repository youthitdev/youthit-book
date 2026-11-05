-- 한끗독서 마이그레이션 155
-- 책방의 교환 인증 사진을 「요청할 때 필수」로 (2026-11-05 사용자 결정)
--
-- 【왜】 책 교환 인증 사진은 후기 탭에 보이는 인증이자 정산 확인의 근거다. 나중에 올리게 두면 책방이 일을 두 번 하고,
--   사진 없는 건이 쌓인다. 책을 건네는 그 자리가 사진을 찍을 수 있는 유일한 때다.
--
-- 【무엇을】 사진이 없으면 요청이 들어가지 않는다 (책방 화면도 같이 막는다 — 서버가 마지막 문이다).
--   · store_submit (목록에서 요청) — 앞서 사진이 올라 있는 건은 그대로 통과
--   · redeem_qr_confirm (QR 로 요청) · redeem_qr_hold (금액 보류) — 본문은 154 와 같고 사진 검사만 더했다
--   이미 사진 없이 요청된 옛 건은 그대로 두고, 책방 목록의 「사진 올리기」(store_add_proof)로 채운다.
--
-- ⚠️ 152·154 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION store_submit(
  p_key         text,
  p_purchase_id bigint,
  p_amount      int,
  p_receipt     text DEFAULT NULL,
  p_photo       text DEFAULT NULL,
  p_note        text DEFAULT NULL,
  p_book        text DEFAULT NULL
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

  -- 책 교환 인증 사진은 요청할 때 필수다. 앞서 올려 둔 사진이 있으면 그걸로 갈음한다
  IF COALESCE(btrim(p_photo), '') = '' AND COALESCE(btrim(v_row.store_photo_path), '') = '' THEN
    RAISE EXCEPTION '책 교환 인증 사진을 올려 주세요';
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
         store_note         = COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), store_note),
         store_book_title   = COALESCE(NULLIF(btrim(COALESCE(p_book, '')), ''), store_book_title),
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
REVOKE EXECUTE ON FUNCTION store_submit(text, bigint, int, text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_submit(text, bigint, int, text, text, text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION redeem_qr_confirm(
  p_token   text,
  p_code    text,
  p_amount  int,
  p_receipt text DEFAULT NULL,
  p_photo   text DEFAULT NULL,
  p_note    text DEFAULT NULL,
  p_book    text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE r redemptions; v_cap int; v_pid bigint; v_store text; v_chk text; a uuid;
BEGIN
  SELECT * INTO r FROM redemptions WHERE token = p_token FOR UPDATE;
  IF NOT FOUND             THEN RETURN qr_fail('쪽지를 찾지 못했어요'); END IF;
  IF r.status = 'done'     THEN RETURN qr_fail('이미 끝난 교환이에요'); END IF;
  IF r.status <> 'issued'  THEN RETURN qr_fail('쓸 수 없는 쪽지예요'); END IF;
  IF r.expires_at <= now() THEN RETURN qr_fail('시간이 지났어요. 청소년에게 다시 띄워달라고 해주세요'); END IF;
  IF COALESCE(btrim(p_photo), '') = '' THEN RETURN qr_fail('책 교환 인증 사진을 올려 주세요'); END IF;

  v_chk := store_code_check(r.bookstore_id, p_code);
  IF v_chk = 'locked' THEN RETURN qr_fail('번호를 여러 번 잘못 넣어서 잠시 잠겼어요. 10분 뒤에 다시 해주세요'); END IF;
  IF v_chk <> 'ok'    THEN RETURN qr_fail('책방 고유 번호가 달라요'); END IF;

  -- 쪽지를 띄운 뒤에 이 아이의 다른 교환이 기록됐다면, 같은 교환권을 두 번 쓰는 것이다
  PERFORM pg_advisory_xact_lock(hashtext('redeem:' || r.user_id::text));
  IF EXISTS (SELECT 1 FROM book_purchases bp
              WHERE bp.user_id = r.user_id AND bp.status IN ('pending', 'settled')
                AND bp.created_at > r.issued_at) THEN
    RETURN qr_fail('이 청소년은 쪽지를 띄운 뒤에 다른 교환이 기록됐어요. 청소년에게 다시 띄워달라고 해주세요');
  END IF;

  IF p_amount IS NULL OR p_amount <= 0 THEN RETURN qr_fail('금액을 적어주세요'); END IF;
  v_cap := COALESCE((SELECT voucher_max_amount FROM dokseo_settings WHERE id = 1), 20000);
  IF p_amount > v_cap THEN
    RETURN qr_fail('한 권에 쓸 수 있는 금액을 넘어요 (최대 ' || to_char(v_cap, 'FM999,999') || '원)');
  END IF;

  INSERT INTO book_purchases(user_id, routine_id, bookstore_id, code_ok,
                             store_amount, store_receipt_path, store_photo_path,
                             store_note, store_book_title, store_submitted_at)
  VALUES (r.user_id, r.routine_id, r.bookstore_id, true,
          p_amount, p_receipt, p_photo,
          NULLIF(btrim(COALESCE(p_note, '')), ''), NULLIF(btrim(COALESCE(p_book, '')), ''), now())
  RETURNING id INTO v_pid;

  UPDATE redemptions SET status = 'done', purchase_id = v_pid, done_at = now() WHERE id = r.id;
  SELECT name INTO v_store FROM bookstores WHERE id = r.bookstore_id;

  BEGIN
    PERFORM notify_push(r.user_id, '책을 받았어요 📚',
      v_store || ' · 책을 잘 받았어요', '/youthit-book/app.html?tab=my');
    FOR a IN SELECT * FROM admin_user_ids() LOOP
      PERFORM notify_push(a, '책방이 비용을 청구했어요 🧾',
        v_store || ' · ' || to_char(p_amount, 'FM999,999') || '원 · 확인해 주세요',
        '/youthit-book/admin.html');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'purchase_id', v_pid, 'amount', p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_qr_confirm(text, text, int, text, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION redeem_qr_confirm(text, text, int, text, text, text, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION redeem_qr_hold(
  p_token text,
  p_code  text,
  p_photo text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE r redemptions; v_pid bigint; v_store text; v_chk text; a uuid;
BEGIN
  SELECT * INTO r FROM redemptions WHERE token = p_token FOR UPDATE;
  IF NOT FOUND             THEN RETURN qr_fail('쪽지를 찾지 못했어요'); END IF;
  IF r.status = 'done'     THEN RETURN qr_fail('이미 끝난 교환이에요'); END IF;
  IF r.status <> 'issued'  THEN RETURN qr_fail('쓸 수 없는 쪽지예요'); END IF;
  IF r.expires_at <= now() THEN RETURN qr_fail('시간이 지났어요. 청소년에게 다시 띄워달라고 해주세요'); END IF;
  IF COALESCE(btrim(p_photo), '') = '' THEN RETURN qr_fail('책 교환 인증 사진을 올려 주세요'); END IF;

  v_chk := store_code_check(r.bookstore_id, p_code);
  IF v_chk = 'locked' THEN RETURN qr_fail('번호를 여러 번 잘못 넣어서 잠시 잠겼어요. 10분 뒤에 다시 해주세요'); END IF;
  IF v_chk <> 'ok'    THEN RETURN qr_fail('책방 고유 번호가 달라요'); END IF;

  PERFORM pg_advisory_xact_lock(hashtext('redeem:' || r.user_id::text));
  IF EXISTS (SELECT 1 FROM book_purchases bp
              WHERE bp.user_id = r.user_id AND bp.status IN ('pending', 'settled')
                AND bp.created_at > r.issued_at) THEN
    RETURN qr_fail('이 청소년은 쪽지를 띄운 뒤에 다른 교환이 기록됐어요. 청소년에게 다시 띄워달라고 해주세요');
  END IF;

  INSERT INTO book_purchases(user_id, routine_id, bookstore_id, code_ok, store_photo_path)
  VALUES (r.user_id, r.routine_id, r.bookstore_id, true, p_photo)
  RETURNING id INTO v_pid;

  UPDATE redemptions SET status = 'done', purchase_id = v_pid, done_at = now() WHERE id = r.id;
  SELECT name INTO v_store FROM bookstores WHERE id = r.bookstore_id;

  BEGIN
    PERFORM notify_push(r.user_id, '책을 받았어요 📚',
      v_store || ' · 책을 잘 받았어요', '/youthit-book/app.html?tab=my');
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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 셋 다 1 (사진 검사 문구가 들어 있다)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'store_submit'       AND prosrc LIKE '%책 교환 인증 사진을 올려 주세요%') AS 목록요청_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'redeem_qr_confirm'  AND prosrc LIKE '%책 교환 인증 사진을 올려 주세요%') AS QR요청_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'redeem_qr_hold'     AND prosrc LIKE '%책 교환 인증 사진을 올려 주세요%') AS 보류_1이어야;
