-- 한끗독서 마이그레이션 154
-- 책 교환 인증을 「책방지기가 올린 사진」으로 (2026-11-05 사용자 결정)
--
-- 【바뀌는 것】
--   · 후기 탭의 「책 교환 인증」은 책방이 책 값을 요청할 때(또는 나중에) 올린 교환 인증 사진을 보인다.
--     청소년이 올리던 사진 화면은 앱에서 없앴다. 닉네임·「왜 골랐어요」 글은 책방 사진에 붙지 않는다.
--   · 옛 청소년 사진(공개로 남긴 것)은 책방 사진이 없는 건에 한해 그대로 보인다.
--
-- 【무엇을】
--   1. book_purchases.exchange_hidden — 이 건의 사진을 앱 피드에서 내린다 (운영진이 SQL 로: UPDATE book_purchases SET exchange_hidden = true WHERE id = 번호;)
--   2. 로그인한 사람이 「교환 인증으로 쓰는 사진」만 읽게 저장소 정책을 연다. 같은 저장소의 영수증은 여전히 운영진만 읽는다.
--   3. exchange_feed — 책방 사진(photo_path)을 우선으로, 칸이 늘어 지우고 다시 만든다.
--   4. redeem_qr_confirm · redeem_qr_hold — 책 받음 알림 문구에서 「한 장 남겨주세요」를 뺀다 (본문은 152 와 같다).
--
-- ⚠️ 85·97·152 뒤에 돌린다. 여러 번 돌려도 된다.
-- ⚠️ 돌리기 전에 관리자 화면에서 이미 올라온 책방 사진을 한 번 훑어 보세요. 얼굴이 나온 사진은 exchange_hidden 으로 내립니다.

-- ── 1. 내리기 칸 ───────────────────────────────────────
ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS exchange_hidden boolean NOT NULL DEFAULT false;

-- ── 2. 저장소 정책 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION is_exchange_photo(p_name text) RETURNS boolean AS $$
  SELECT EXISTS (SELECT 1 FROM book_purchases b
                  WHERE b.store_photo_path = p_name AND b.status <> 'void' AND NOT b.exchange_hidden)
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION is_exchange_photo(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION is_exchange_photo(text) TO authenticated;

DROP POLICY IF EXISTS store_proofs_exchange_read ON storage.objects;
CREATE POLICY store_proofs_exchange_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id = 'store-proofs' AND public.is_exchange_photo(name));

-- ── 3. 피드 ────────────────────────────────────────────
DROP FUNCTION IF EXISTS exchange_feed(int);

CREATE OR REPLACE FUNCTION exchange_feed(p_limit int DEFAULT 30)
RETURNS TABLE (id bigint, photo_url text, photo_path text, reason text, nick text, day date, store_name text) AS $$
  WITH x AS (
    SELECT b.*, NULLIF(btrim(COALESCE(b.store_photo_path, '')), '') AS sp,
           COALESCE(NULLIF(btrim(b.book_photo_url), ''),
                    CASE WHEN b.proof_photo_url LIKE 'http%' THEN b.proof_photo_url END) AS kp
      FROM book_purchases b
     WHERE b.status <> 'void' AND NOT b.exchange_hidden
  )
  SELECT x.id,
         CASE WHEN x.sp IS NULL THEN x.kp END,
         x.sp,
         CASE WHEN x.sp IS NULL THEN NULLIF(btrim(COALESCE(x.pick_reason, '')), '') END,
         CASE WHEN x.sp IS NULL THEN COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '익명') END,
         (x.created_at AT TIME ZONE 'Asia/Seoul')::date,
         s.name
    FROM x
    LEFT JOIN profiles   p ON p.id = x.user_id
    LEFT JOIN bookstores s ON s.id = x.bookstore_id
   WHERE x.sp IS NOT NULL OR (x.photo_public AND x.kp IS NOT NULL)
   ORDER BY x.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 60)
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION exchange_feed(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION exchange_feed(int) TO authenticated;

-- ── 4. 알림 문구 ───────────────────────────────────────
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
-- 기대: 피드 함수가 새 칸(photo_path)을 가진 것 1 · 정책 1 · 책방 사진이 있는 건 수만큼 피드에 나온다
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'exchange_feed' AND pg_get_function_result(oid) LIKE '%photo_path%') AS 피드_새판_1이어야,
       (SELECT count(*) FROM pg_policies WHERE policyname = 'store_proofs_exchange_read')                                  AS 정책_1이어야,
       (SELECT count(*) FROM book_purchases WHERE store_photo_path IS NOT NULL AND status <> 'void')                        AS 책방사진_건수,
       (SELECT count(*) FROM exchange_feed(60))                                                                             AS 지금_피드에_보이는_수;
