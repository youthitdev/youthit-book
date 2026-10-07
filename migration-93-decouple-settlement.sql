-- 한끗독서 마이그레이션 93
-- 정산이 끝나지 않아도 아이는 새 교환을 할 수 있다
--
-- 【무엇이 막고 있었나】 「한 루틴에 정산 대기 건은 하나만」 (book_purchases_one_pending_idx).
--   교환권이 2장인 아이가 첫 교환의 정산이 끝나기 전에 두 번째 QR 을 찍으면, 사장님 화면에서
--   알 수 없는 DB 오류로 실패했다. 앱도 정산 대기가 있으면 교환 단추를 숨겼다.
--   아이에게 교환은 끝난 일이고 정산은 유스보이스 안쪽 사정이다 (2026-10-07 사용자).
--
-- 【그 제한은 무엇을 지키고 있었나】 옛 방식(아이가 혼자 기록)에는 서버가 교환권 수를 세지 않았다.
--   이 제한이 유일한 서버 쪽 브레이크였다. QR 은 쪽지를 띄울 때 서버가 교환권을 본다.
--   그러니 제한을 풀면서 **같은 일을 하는 확인을 대신 넣는다.** 안 넣으면 풀자마자 옛 방식으로
--   교환권 없이 구매를 무한히 기록하는 구멍이 생긴다.
--
--     ① redeem_voucher (옛 방식)  서버가 남은 교환권을 직접 센다 + 같은 사람의 동시 호출은 줄 세운다
--     ② redeem_qr_confirm/hold   쪽지를 띄운 **뒤에** 이 아이의 다른 교환이 기록됐으면 막는다
--                                (띄워 둔 사이에 옛 방식으로 같은 교환권을 쓰는 경우)
--
-- 【돈 길은 그대로다】 구매가 늘어도 돈은 사장님 청구와 운영진 확정이 있어야 나간다.
--
-- 【번호를 맞혀볼 수 있는 길을 같이 닫는다】 번호(네 자리)는 이제 책방 로그인 열쇠다.
--   · bookstore_by_code  로그인한 아이가 1만 번 불러 번호를 알아낼 수 있었다(횟수 제한 없음).
--                        지금 아이 화면은 쓰지 않는다 → 아이에게서 거둔다
--   · redeem_voucher 의 번호 갈래  같은 일을 한다 → 번호로는 더 받지 않는다
--
-- ⚠️ 73(redeem_voucher) · 88·91·92(쪽지) 뒤에 돌린다.

-- ── 1. 「정산 대기 1건」 제한을 푼다 ────────────────────
DROP INDEX IF EXISTS book_purchases_one_pending_idx;

-- ── 2. 번호를 맞혀볼 수 있는 길을 닫는다 ───────────────
REVOKE EXECUTE ON FUNCTION bookstore_by_code(text) FROM PUBLIC, anon, authenticated;

-- ── 3. 옛 방식: 서버가 교환권을 센다 ───────────────────
CREATE OR REPLACE FUNCTION redeem_voucher(
  p_routine_id bigint,
  p_code       text   DEFAULT NULL,
  p_store_id   bigint DEFAULT NULL,
  p_proof      text   DEFAULT NULL,
  p_public     text   DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE v_store bigint; v_name text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;

  -- 번호로는 더 받지 않는다 (위의 이유). 아이 화면은 이미 책방 고르기만 쓴다
  IF COALESCE(btrim(p_code), '') <> '' THEN
    RAISE EXCEPTION '번호로 하는 교환은 더 쓰지 않아요. QR 로 해주세요';
  END IF;

  -- 같은 사람이 동시에 두 번 불러도 둘 다 「교환권이 있다」고 보지 않게 줄을 세운다
  PERFORM pg_advisory_xact_lock(hashtext('redeem:' || auth.uid()::text));

  IF COALESCE((dokseo_points(auth.uid()) ->> 'left')::int, 0) < 1 THEN
    RAISE EXCEPTION '아직 쓸 수 있는 교환권이 없어요';
  END IF;

  SELECT b.id, b.name INTO v_store, v_name
    FROM bookstores b WHERE b.id = p_store_id AND b.active;
  IF v_store IS NULL THEN RAISE EXCEPTION '책방을 골라주세요'; END IF;

  -- 청소년인지, 공유회를 다녀왔는지는 check_purchase_verified 가 본다
  INSERT INTO book_purchases (user_id, routine_id, bookstore_id,
                              proof_photo_url, book_photo_url, code_ok)
  VALUES (auth.uid(), p_routine_id, v_store, p_proof, p_public, false);

  RETURN jsonb_build_object('bookstore_id', v_store, 'bookstore', v_name, 'code_ok', false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_voucher(bigint, text, bigint, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION redeem_voucher(bigint, text, bigint, text, text) TO authenticated;

-- ── 4. QR: 쪽지를 띄운 뒤에 다른 교환이 끼어들었으면 막는다 ──
-- 91 의 본문 그대로에 그 확인 한 덩어리만 더했다
CREATE OR REPLACE FUNCTION redeem_qr_confirm(
  p_token   text,
  p_code    text,
  p_amount  int,
  p_receipt text DEFAULT NULL,
  p_photo   text DEFAULT NULL,
  p_note    text DEFAULT NULL
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
  IF v_chk <> 'ok'    THEN RETURN qr_fail('확인 번호가 달라요'); END IF;

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
                             store_note, store_submitted_at)
  VALUES (r.user_id, r.routine_id, r.bookstore_id, true,
          p_amount, p_receipt, p_photo,
          NULLIF(btrim(COALESCE(p_note, '')), ''), now())
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
REVOKE EXECUTE ON FUNCTION redeem_qr_confirm(text, text, int, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION redeem_qr_confirm(text, text, int, text, text, text) TO anon, authenticated;

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
  IF v_chk <> 'ok'    THEN RETURN qr_fail('확인 번호가 달라요'); END IF;

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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- redeem_voucher 는 로그인한 사람만 부를 수 있고 구매를 실제로 만들어서, 여기서 불러 보지 않는다.
-- (만들어지기만 한 것을 믿다 당한 적이 있다 — 대신 새로 더한 식들을 따로 돌려 본다.)
SELECT
  (SELECT count(*) FROM pg_indexes WHERE indexname = 'book_purchases_one_pending_idx') AS 제한_0이어야,
  NOT has_function_privilege('authenticated', 'bookstore_by_code(text)', 'EXECUTE')    AS 번호조회_닫힘_true여야,
  (SELECT count(*) FROM pg_proc
    WHERE proname IN ('redeem_voucher', 'redeem_qr_confirm', 'redeem_qr_hold'))        AS 함수셋_3이어야,
  (SELECT count(*) FROM book_purchases bp JOIN redemptions r
      ON r.user_id = bp.user_id AND bp.created_at > r.issued_at
     AND bp.status IN ('pending', 'settled'))                                          AS 끼어든구매_식_돌아가나;
