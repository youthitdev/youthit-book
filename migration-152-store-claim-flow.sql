-- 한끗독서 마이그레이션 152
-- 책방의 「책 값 요청하기」 — 책 이름을 받고, 영수증·교환 인증 사진은 나중에 올릴 수 있게 (2026-10-28 요청: 리워드 교환 화면 수정안)
--
-- 【바뀌는 것】
--   · 책방이 책 값을 요청할 때 「책 이름」도 적는다(선택). 책 값만 있으면 요청이 들어간다.
--   · 영수증 사진·교환 인증 사진은 **요청한 뒤에도** 올릴 수 있다 (새 함수 store_add_proof). 요청 후 3일 안을 안내한다(막지는 않는다).
--   · 사장님이 보는 말에서 「확인 번호」를 「책방 고유 번호」로 바꾼다 (번호 틀림·미설정 안내문).
--
-- 【무엇을】
--   1. book_purchases.store_book_title 칸
--   2. store_pending: 책 이름, 영수증·사진이 올라왔는지(has_receipt · has_photo)를 더 돌려준다 — 칸이 늘어 지우고 다시 만든다
--   3. store_submit / redeem_qr_confirm: p_book 을 받는다 — 칸이 늘어 옛 모양을 지우고 다시 만든다.
--      store_submit 은 남길 말(note)을 비워 보내도 앞서 적은 것을 지우지 않는다
--   4. store_add_proof: 이미 요청한 건에 사진을 더 올린다 (없던 칸만 채우고, 있던 사진은 새로 올린 것으로 바꾼다)
--   5. redeem_qr_lookup · redeem_qr_hold · store_login: 안내문 문구만 바꿔 다시 만든다
--
-- ⚠️ 85·91·92·93 뒤에 돌린다. 여러 번 돌려도 된다.

ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS store_book_title text;

-- ── 2. 청구 목록 ───────────────────────────────────────
DROP FUNCTION IF EXISTS store_pending(text);
CREATE OR REPLACE FUNCTION store_pending(p_key text)
RETURNS TABLE (
  id bigint, who text, kid_age int, came_at timestamptz,
  code_ok boolean, store_amount int, submitted boolean, settled boolean,
  store_book text, has_receipt boolean, has_photo boolean
) AS $$
DECLARE v_store bigint;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  RETURN QUERY
  SELECT g.id,
         COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '이름 없음'),
         age_years(pp.birth_date),
         g.created_at,
         COALESCE(g.code_ok, false),
         g.store_amount,
         g.store_submitted_at IS NOT NULL,
         g.status = 'settled',
         g.store_book_title,
         g.store_receipt_path IS NOT NULL,
         g.store_photo_path IS NOT NULL
    FROM book_purchases g
    LEFT JOIN profiles         p  ON p.id  = g.user_id
    LEFT JOIN profiles_private pp ON pp.id = g.user_id
   WHERE g.bookstore_id = v_store
     AND g.status <> 'void'
     AND g.created_at > now() - interval '60 days'
   ORDER BY g.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION store_pending(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_pending(text) TO anon, authenticated;

-- ── 3. 책 값 요청 (목록에서) ───────────────────────────
DROP FUNCTION IF EXISTS store_submit(text, bigint, int, text, text, text);
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

-- ── 3. 책 값 요청 (QR 로 들어와서) ─────────────────────
DROP FUNCTION IF EXISTS redeem_qr_confirm(text, text, int, text, text, text);
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
      v_store || ' · 받은 책을 한 장 남겨주세요', '/youthit-book/app.html?tab=my');
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

-- ── 4. 사진 나중에 올리기 ──────────────────────────────
CREATE OR REPLACE FUNCTION store_add_proof(
  p_key         text,
  p_purchase_id bigint,
  p_receipt     text DEFAULT NULL,
  p_photo       text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE v_store bigint; v_row book_purchases;
BEGIN
  v_store := store_of_key(p_key);
  IF v_store IS NULL THEN RAISE EXCEPTION '주소가 올바르지 않아요'; END IF;

  SELECT * INTO v_row FROM book_purchases
   WHERE id = p_purchase_id AND bookstore_id = v_store FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '우리 책방 건이 아니에요'; END IF;
  IF v_row.status = 'void' THEN RAISE EXCEPTION '취소된 건이에요'; END IF;
  IF p_receipt IS NULL AND p_photo IS NULL THEN RAISE EXCEPTION '올릴 사진을 골라주세요'; END IF;

  UPDATE book_purchases
     SET store_receipt_path = COALESCE(p_receipt, store_receipt_path),
         store_photo_path   = COALESCE(p_photo,   store_photo_path)
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('ok', true, 'id', p_purchase_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_add_proof(text, bigint, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_add_proof(text, bigint, text, text) TO anon, authenticated;

-- ── 5. 문구만 바꿔 다시 만든다 ─────────────────────────
CREATE OR REPLACE FUNCTION redeem_qr_lookup(p_token text, p_code text) RETURNS jsonb AS $$
DECLARE r redemptions; v_chk text; v_who text; v_routine text; v_store text; v_age int;
BEGIN
  SELECT * INTO r FROM redemptions WHERE token = p_token;
  IF NOT FOUND             THEN RETURN qr_fail('쪽지를 찾지 못했어요'); END IF;
  IF r.status = 'done'     THEN RETURN qr_fail('이미 끝난 교환이에요'); END IF;
  IF r.status <> 'issued'  THEN RETURN qr_fail('쓸 수 없는 쪽지예요'); END IF;
  IF r.expires_at <= now() THEN RETURN qr_fail('시간이 지났어요. 청소년에게 다시 띄워달라고 해주세요'); END IF;

  v_chk := store_code_check(r.bookstore_id, p_code);
  IF v_chk = 'locked' THEN RETURN qr_fail('번호를 여러 번 잘못 넣어서 잠시 잠겼어요. 10분 뒤에 다시 해주세요'); END IF;
  IF v_chk <> 'ok'    THEN RETURN qr_fail('책방 고유 번호가 달라요'); END IF;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '이름 없음')
    INTO v_who FROM profiles p WHERE p.id = r.user_id;
  SELECT age_years(pp.birth_date) INTO v_age FROM profiles_private pp WHERE pp.id = r.user_id;
  SELECT ro.title INTO v_routine FROM routines ro WHERE ro.id = r.routine_id;
  SELECT b.name   INTO v_store   FROM bookstores b WHERE b.id = r.bookstore_id;

  RETURN jsonb_build_object('ok', true, 'who', v_who, 'age', v_age, 'routine', v_routine,
    'bookstore', v_store, 'bookstore_id', r.bookstore_id,
    'left_sec', GREATEST(0, EXTRACT(epoch FROM (r.expires_at - now()))::int));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_qr_lookup(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION redeem_qr_lookup(text, text) TO anon, authenticated;

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

CREATE OR REPLACE FUNCTION store_login(p_store_id bigint, p_code text) RETURNS jsonb AS $$
DECLARE v_name text; v_key text; v_res text; v_until timestamptz;
BEGIN
  SELECT name INTO v_name FROM bookstores WHERE id = p_store_id AND active;
  IF v_name IS NULL THEN RETURN qr_fail('책방을 찾지 못했어요'); END IF;

  -- 번호가 아직 없는 책방은 들어올 수 없다. 틀린 횟수에도 넣지 않는다
  IF NOT EXISTS (SELECT 1 FROM bookstore_codes WHERE bookstore_id = p_store_id) THEN
    RETURN qr_fail('이 책방은 책방 고유 번호가 아직 정해지지 않았어요. 메일로 알려주세요');
  END IF;

  v_res := store_code_check(p_store_id, p_code);
  IF v_res = 'locked' THEN
    RETURN qr_fail('번호를 여러 번 잘못 넣어서 잠시 잠겼어요. 10분 뒤에 다시 해주세요');
  END IF;
  IF v_res <> 'ok' THEN RETURN qr_fail('책방 고유 번호가 달라요'); END IF;

  SELECT access_key INTO v_key FROM bookstore_keys WHERE bookstore_id = p_store_id;
  IF v_key IS NULL THEN
    -- gen_random_uuid() 는 코어 함수라 확장(pgcrypto)이 없어도 돈다
    v_key := replace(gen_random_uuid()::text, '-', '');
    INSERT INTO bookstore_keys(bookstore_id, access_key) VALUES (p_store_id, v_key);
  END IF;

  RETURN jsonb_build_object('ok', true, 'key', v_key, 'name', v_name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_login(bigint, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_login(bigint, text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM information_schema.columns WHERE table_name = 'book_purchases' AND column_name = 'store_book_title') AS 칸_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'store_add_proof')                                                               AS 사진함수_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname IN ('store_submit', 'redeem_qr_confirm') AND pronargs = 7)                         AS 새모양_2여야,
       (SELECT count(*) FROM pg_proc WHERE proname IN ('store_login', 'redeem_qr_lookup', 'redeem_qr_hold') AND prosrc LIKE '%책방 고유 번호%') AS 문구_3이어야;
