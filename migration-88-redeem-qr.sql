-- 한끗독서 마이그레이션 88
-- 아이 폰에 QR 을 띄우고, 사장님이 카메라로 찍는다
--
-- 【왜 바꾸나】 지금은 사장님이 **아이 폰을 받아들고** 네 자리를 누른다.
--   남의 폰에 숫자를 넣는 일은 생각보다 어색하고, 그 뒤에 사장님이 다시
--   제 폰으로 목록에서 그 아이를 **찾아야** 한다. 아이가 여럿 다녀간 날엔
--   누가 누군지 헷갈린다.
--   QR 이면 카메라만 비추면 되고, **그 건이 바로 열린다.**
--
-- 【QR 에 책방 열쇠를 담지 않는다】 담으면 아이 폰 안에 그 책방의 전체
--   교환 내역을 여는 열쇠가 들어간다. 캡처 한 장이면 남의 기록까지 보인다.
--   **그 건 하나만, 15분만 여는 일회용 쪽지**를 담는다.
--
-- 【누가 확정하나 — 사장님이다】 쪽지를 스캔한 것만으로는 아무 일도 안 난다.
--   사장님이 **제 폰에 우리 책방 네 자리**를 넣어야 확정된다. 그래야 아이가
--   혼자 제 QR 을 찍어 교환을 지어내지 못한다. 네 자리가 **아이 폰에서
--   사장님 폰으로 옮겨가는 것**이고, 그게 원래 있어야 할 자리다.
--
-- 【순서가 뒤집힌다】
--     지금    아이: 네 자리 → 사진 → 기록   ·   사장님: 목록에서 찾아 청구
--     바뀌면  아이: QR → 사장님 스캔 → 금액·영수증·사진 → 확정
--             그다음 아이 앱에 「책을 받았어요」 → 사진·후기
--   DESIGN-서점교환.md 의 「돈은 서점, 기록은 청소년」이 그제야 완성된다.
--
-- 【옛 길은 지우지 않는다】 카메라가 안 되는 폰, 어두운 가게, 안 읽히는 QR 이
--   반드시 있다. redeem_voucher(네 자리) 는 그대로 살려 둔다.
--
-- ⚠️ 73(bookstore_codes·redeem_voucher) · 85(store 열쇠) 뒤에 돌린다.

-- ── 1. 일회용 쪽지 ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS redemptions (
  id           bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  token        text   NOT NULL UNIQUE,
  user_id      uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  routine_id   bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  bookstore_id bigint NOT NULL REFERENCES bookstores(id) ON DELETE CASCADE,
  status       text   NOT NULL DEFAULT 'issued'
                 CHECK (status IN ('issued','done','canceled','expired')),
  purchase_id  bigint REFERENCES book_purchases(id) ON DELETE SET NULL,
  issued_at    timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  done_at      timestamptz
);
CREATE INDEX IF NOT EXISTS redemptions_user_idx ON redemptions(user_id, issued_at DESC);

-- 한 사람이 동시에 두 장을 띄우지 못한다. 두 책방에서 한꺼번에 쓰는 걸 막는다
CREATE UNIQUE INDEX IF NOT EXISTS redemptions_one_live_idx
  ON redemptions(user_id) WHERE status = 'issued';

ALTER TABLE redemptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS redeem_own ON redemptions;
CREATE POLICY redeem_own ON redemptions FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin());

-- ── 2. 아이가 쪽지를 띄운다 ────────────────────────────
CREATE OR REPLACE FUNCTION redeem_qr_issue(p_routine_id bigint, p_store_id bigint)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := auth.uid();
  v_tok text; v_exp timestamptz; v_name text; v_left int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;

  -- 책방부터. 없는 책방이면 뒤를 볼 것도 없다
  SELECT name INTO v_name FROM bookstores WHERE id = p_store_id AND active;
  IF v_name IS NULL THEN RAISE EXCEPTION '책방을 골라주세요'; END IF;

  -- 【여기서 다 본다】 확정은 로그인 없는 사장님 화면에서 일어나므로,
  --   그때는 auth.uid() 가 비어 check_purchase_verified 가 비켜선다.
  --   막을 것은 전부 이 자리에서 막는다
  IF COALESCE((SELECT role FROM profiles WHERE id = v_u), 'youth') <> 'youth' THEN
    RAISE EXCEPTION '도서기금은 청소년에게 쓰는 돈이에요';
  END IF;
  IF COALESCE((SELECT verify_status FROM profiles WHERE id = v_u), 'none') <> 'approved' THEN
    RAISE EXCEPTION '청소년 확인이 끝나야 책을 받을 수 있어요';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM routine_participants
                  WHERE routine_id = p_routine_id AND user_id = v_u AND status = 'approved') THEN
    RAISE EXCEPTION '참여 중인 루틴이 아니에요';
  END IF;
  IF COALESCE((SELECT meetup_required FROM routines WHERE id = p_routine_id), false)
     AND (SELECT met_at FROM routine_participants
           WHERE routine_id = p_routine_id AND user_id = v_u) IS NULL THEN
    RAISE EXCEPTION '공유회에 참석해야 책을 받을 수 있어요';
  END IF;

  v_left := COALESCE((dokseo_points(v_u) ->> 'left')::int, 0);
  IF v_left < 1 THEN RAISE EXCEPTION '아직 쓸 수 있는 교환권이 없어요'; END IF;

  -- 아직 살아 있는 쪽지가 있으면 그걸 그대로 돌려준다.
  -- 새로 만들면 유일 인덱스에 걸려 「알 수 없는 오류」가 난다
  SELECT r.token, r.expires_at INTO v_tok, v_exp
    FROM redemptions r
   WHERE r.user_id = v_u AND r.status = 'issued' AND r.expires_at > now()
   ORDER BY r.issued_at DESC LIMIT 1;
  IF v_tok IS NOT NULL THEN
    RETURN jsonb_build_object('token', v_tok, 'expires_at', v_exp, 'bookstore', v_name, 'reused', true);
  END IF;

  -- 지나간 것은 정리하고 간다
  UPDATE redemptions SET status = 'expired'
   WHERE user_id = v_u AND status = 'issued' AND expires_at <= now();

  v_tok := substr(md5(random()::text || clock_timestamp()::text), 1, 16)
        || substr(md5(random()::text || v_u::text), 1, 16);
  v_exp := now() + interval '15 minutes';

  INSERT INTO redemptions(token, user_id, routine_id, bookstore_id, expires_at)
  VALUES (v_tok, v_u, p_routine_id, p_store_id, v_exp);

  RETURN jsonb_build_object('token', v_tok, 'expires_at', v_exp, 'bookstore', v_name, 'reused', false);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_qr_issue(bigint, bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION redeem_qr_issue(bigint, bigint) TO authenticated;

-- ── 3. 아이가 쪽지를 접는다 ────────────────────────────
CREATE OR REPLACE FUNCTION redeem_qr_cancel(p_token text) RETURNS void AS $$
BEGIN
  UPDATE redemptions SET status = 'canceled'
   WHERE token = p_token AND user_id = auth.uid() AND status = 'issued';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_qr_cancel(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION redeem_qr_cancel(text) TO authenticated;

-- ── 4. 사장님이 스캔해서 들여다본다 ────────────────────
-- 네 자리를 **사장님 제 폰에** 넣는다. 이게 「이 책방이 맞다」는 증거다
CREATE OR REPLACE FUNCTION redeem_qr_lookup(p_token text, p_code text)
RETURNS TABLE (who text, routine text, bookstore text, left_sec int) AS $$
DECLARE r redemptions;
BEGIN
  SELECT * INTO r FROM redemptions WHERE token = p_token;
  IF NOT FOUND              THEN RAISE EXCEPTION '쪽지를 찾지 못했어요'; END IF;
  IF r.status = 'done'      THEN RAISE EXCEPTION '이미 끝난 교환이에요'; END IF;
  IF r.status <> 'issued'   THEN RAISE EXCEPTION '쓸 수 없는 쪽지예요'; END IF;
  IF r.expires_at <= now()  THEN RAISE EXCEPTION '시간이 지났어요. 청소년에게 다시 띄워달라고 해주세요'; END IF;

  IF NOT EXISTS (SELECT 1 FROM bookstore_codes c
                  WHERE c.bookstore_id = r.bookstore_id AND btrim(c.code) = btrim(p_code)) THEN
    RAISE EXCEPTION '확인 번호가 달라요';
  END IF;

  RETURN QUERY
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '이름 없음'),
         ro.title, b.name,
         GREATEST(0, EXTRACT(epoch FROM (r.expires_at - now()))::int)
    FROM profiles p, routines ro, bookstores b
   WHERE p.id = r.user_id AND ro.id = r.routine_id AND b.id = r.bookstore_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION redeem_qr_lookup(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION redeem_qr_lookup(text, text) TO anon, authenticated;

-- ── 5. 사장님이 확정한다 ───────────────────────────────
CREATE OR REPLACE FUNCTION redeem_qr_confirm(
  p_token   text,
  p_code    text,
  p_amount  int,
  p_receipt text DEFAULT NULL,
  p_photo   text DEFAULT NULL,
  p_note    text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE r redemptions; v_cap int; v_pid bigint; v_store text; a uuid;
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

  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION '금액을 적어주세요'; END IF;
  v_cap := COALESCE((SELECT voucher_max_amount FROM dokseo_settings WHERE id = 1), 20000);
  IF p_amount > v_cap THEN
    RAISE EXCEPTION '한 권에 쓸 수 있는 금액을 넘어요 (최대 %원)', to_char(v_cap, 'FM999,999');
  END IF;

  -- 아이 사진은 아직 없다. 책을 받고 나서 제 앱에서 올린다
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
    -- 아이에게: 이제 사진을 남길 차례다
    PERFORM notify_push(r.user_id, '책을 받았어요 📚',
      v_store || ' · 받은 책을 한 장 남겨주세요',
      '/youthit-book/app.html?tab=my');
    -- 운영진에게: 확인하고 책값을 보낼 차례다
    FOR a IN SELECT * FROM admin_user_ids() LOOP
      PERFORM notify_push(a, '책방이 비용을 청구했어요 🧾',
        v_store || ' · ' || to_char(p_amount, 'FM999,999') || '원 · 확인해 주세요',
        '/youthit-book/admin.html');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN NULL;   -- 알림이 터져도 교환은 끝난다
  END;

  RETURN jsonb_build_object('ok', true, 'purchase_id', v_pid, 'amount', p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_qr_confirm(text, text, int, text, text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION redeem_qr_confirm(text, text, int, text, text, text) TO anon, authenticated;

-- ── 6. 지나간 쪽지 치우기 ──────────────────────────────
CREATE OR REPLACE FUNCTION expire_redemptions() RETURNS int AS $$
DECLARE n int;
BEGIN
  UPDATE redemptions SET status = 'expired'
   WHERE status = 'issued' AND expires_at <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION expire_redemptions() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule('dokseo-expire-redeem')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-expire-redeem');
SELECT cron.schedule('dokseo-expire-redeem', '*/10 * * * *', 'SELECT expire_redemptions()');

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 만들어지기만 한 것은 85 에서 당했다. 쪽지를 하나 띄워 보고 바로 접는다
SELECT (SELECT count(*) FROM pg_proc WHERE proname LIKE 'redeem_qr%')       AS 함수셋,
       (SELECT count(*) FROM pg_tables WHERE tablename = 'redemptions')     AS 쪽지표,
       (SELECT count(*) FROM cron.job WHERE jobname = 'dokseo-expire-redeem') AS 치우는시계,
       (SELECT count(*) FROM bookstore_codes)                               AS 번호있는_책방;
