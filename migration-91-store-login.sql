-- 한끗독서 마이그레이션 91
-- 책방 로그인 (이름 + 네 자리) 과 틀린 번호 막기
--
-- 【왜 필요한가】 사장님 화면(store.html)은 책방마다 32자 비밀 주소로만 열렸다.
--   주소를 잃어버리면 길이 끊기고, 유스보이스는 전화로 상시 응대하기 어렵다.
--   안내문에 이미 적힌 **책방 이름 + 네 자리**로 들어와 주소를 되찾게 한다.
--   (계정은 만들지 않는다 — 일곱 분께 드리기엔 무겁고 도와드릴 사람도 없다.)
--
-- 【그래서 네 자리가 입구 열쇠가 된다 — 막지 않으면 뚫린다】
--   네 자리는 1만 가지뿐이다. 지금도 아이가 제 QR 쪽지를 들고 번호를 바꿔 가며
--   부르면 알아낼 수 있고, 쪽지는 취소해도 교환권이 안 줄어 얼마든지 다시 띄운다.
--   **책방별로 5번 틀리면 10분간 잠근다.** 오래된 실패(10분 전)는 잊는다.
--   잠금을 짧게 둔 이유: 아이가 일부러 틀려서 사장님을 막는 장난을 줄이려고.
--
-- ⚠️ 【오류를 던지면 횟수도 같이 되돌려진다】 PL/pgSQL 에서 RAISE EXCEPTION 은
--   그 함수가 한 일(틀린 횟수 올리기 포함)을 전부 취소한다. 그래서 번호를 검사하는
--   함수들은 틀렸을 때 **오류가 아니라 정상 응답 `{ok:false, message}`** 로 돌려준다.
--   88·90 의 세 함수(lookup·confirm·hold)를 그렇게 다시 쓴다.
--   lookup 은 돌려주는 모양이 바뀌어(TABLE → jsonb) 먼저 지운다.
--
-- ⚠️ 85(열쇠) · 88·90(쪽지) 뒤에 돌린다.

-- ── 1. 틀린 횟수 ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS store_attempts (
  bookstore_id   bigint PRIMARY KEY REFERENCES bookstores(id) ON DELETE CASCADE,
  failed         int NOT NULL DEFAULT 0,
  last_failed_at timestamptz,
  locked_until   timestamptz
);
ALTER TABLE store_attempts ENABLE ROW LEVEL SECURITY;   -- 정책 없음: 함수만 만진다

-- ── 2. 정상 응답으로 돌려주는 오류 ─────────────────────
CREATE OR REPLACE FUNCTION qr_fail(p_msg text) RETURNS jsonb AS $$
  SELECT jsonb_build_object('ok', false, 'message', p_msg);
$$ LANGUAGE sql IMMUTABLE;
REVOKE EXECUTE ON FUNCTION qr_fail(text) FROM PUBLIC, anon, authenticated;

-- ── 3. 번호를 검사하고 횟수를 센다 ─────────────────────
-- 'ok' | 'wrong' | 'locked'.  책방 하나에 하나뿐인 자물쇠다
CREATE OR REPLACE FUNCTION store_code_check(p_store bigint, p_code text) RETURNS text AS $$
DECLARE a store_attempts; v_ok boolean;
BEGIN
  INSERT INTO store_attempts(bookstore_id) VALUES (p_store) ON CONFLICT DO NOTHING;
  SELECT * INTO a FROM store_attempts WHERE bookstore_id = p_store FOR UPDATE;

  IF a.locked_until IS NOT NULL AND a.locked_until > now() THEN RETURN 'locked'; END IF;

  -- 오래된 실패는 잊는다. 사장님이 점심 때 한 번 틀렸다고 저녁에 잠기면 안 된다
  IF a.last_failed_at IS NOT NULL AND a.last_failed_at <= now() - interval '10 minutes' THEN
    UPDATE store_attempts SET failed = 0, locked_until = NULL WHERE bookstore_id = p_store;
    a.failed := 0;
  END IF;

  SELECT EXISTS (SELECT 1 FROM bookstore_codes c
                  WHERE c.bookstore_id = p_store
                    AND btrim(c.code) = btrim(COALESCE(p_code, ''))) INTO v_ok;

  IF v_ok THEN
    UPDATE store_attempts SET failed = 0, last_failed_at = NULL, locked_until = NULL
     WHERE bookstore_id = p_store;
    RETURN 'ok';
  END IF;

  UPDATE store_attempts
     SET failed         = a.failed + 1,
         last_failed_at = now(),
         locked_until   = CASE WHEN a.failed + 1 >= 5 THEN now() + interval '10 minutes' ELSE NULL END
   WHERE bookstore_id = p_store;

  RETURN CASE WHEN a.failed + 1 >= 5 THEN 'locked' ELSE 'wrong' END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_code_check(bigint, text) FROM PUBLIC, anon, authenticated;

-- ── 4. 로그인 화면에 보일 책방 이름 ────────────────────
CREATE OR REPLACE FUNCTION store_names() RETURNS TABLE (id bigint, name text, region text) AS $$
  SELECT b.id, b.name, b.region FROM bookstores b WHERE b.active ORDER BY b.name;
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION store_names() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION store_names() TO anon, authenticated;

-- ── 5. 로그인: 이름 + 네 자리 → 주소 열쇠를 돌려준다 ───
CREATE OR REPLACE FUNCTION store_login(p_store_id bigint, p_code text) RETURNS jsonb AS $$
DECLARE v_name text; v_key text; v_res text; v_until timestamptz;
BEGIN
  SELECT name INTO v_name FROM bookstores WHERE id = p_store_id AND active;
  IF v_name IS NULL THEN RETURN qr_fail('책방을 찾지 못했어요'); END IF;

  -- 번호가 아직 없는 책방은 들어올 수 없다. 틀린 횟수에도 넣지 않는다
  IF NOT EXISTS (SELECT 1 FROM bookstore_codes WHERE bookstore_id = p_store_id) THEN
    RETURN qr_fail('이 책방은 확인 번호가 아직 정해지지 않았어요. 메일로 알려주세요');
  END IF;

  v_res := store_code_check(p_store_id, p_code);
  IF v_res = 'locked' THEN
    RETURN qr_fail('번호를 여러 번 잘못 넣어서 잠시 잠겼어요. 10분 뒤에 다시 해주세요');
  END IF;
  IF v_res <> 'ok' THEN RETURN qr_fail('확인 번호가 달라요'); END IF;

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

-- ── 6. 운영진 열쇠 발급도 같은 방식으로 ────────────────
-- 85 의 store_key 는 gen_random_bytes(pgcrypto)를 썼다. 함수 안에서 확장이 안 보이면
-- 「function does not exist」로 터진다. 한 번도 실제로 불러 보지 못해서 미리 바꾼다
CREATE OR REPLACE FUNCTION store_key(p_bookstore_id bigint, p_reissue boolean DEFAULT false)
RETURNS text AS $$
DECLARE v_key text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  IF p_reissue THEN DELETE FROM bookstore_keys WHERE bookstore_id = p_bookstore_id; END IF;

  SELECT access_key INTO v_key FROM bookstore_keys WHERE bookstore_id = p_bookstore_id;
  IF v_key IS NOT NULL THEN RETURN v_key; END IF;

  v_key := replace(gen_random_uuid()::text, '-', '');
  INSERT INTO bookstore_keys(bookstore_id, access_key) VALUES (p_bookstore_id, v_key);
  RETURN v_key;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION store_key(bigint, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION store_key(bigint, boolean) TO authenticated;

-- ── 7. 쪽지 세 함수를 다시 쓴다 — 틀려도 오류를 던지지 않는다 ──
DROP FUNCTION IF EXISTS redeem_qr_lookup(text, text);

CREATE OR REPLACE FUNCTION redeem_qr_lookup(p_token text, p_code text) RETURNS jsonb AS $$
DECLARE r redemptions; v_chk text; v_who text; v_routine text; v_store text;
BEGIN
  SELECT * INTO r FROM redemptions WHERE token = p_token;
  IF NOT FOUND             THEN RETURN qr_fail('쪽지를 찾지 못했어요'); END IF;
  IF r.status = 'done'     THEN RETURN qr_fail('이미 끝난 교환이에요'); END IF;
  IF r.status <> 'issued'  THEN RETURN qr_fail('쓸 수 없는 쪽지예요'); END IF;
  IF r.expires_at <= now() THEN RETURN qr_fail('시간이 지났어요. 청소년에게 다시 띄워달라고 해주세요'); END IF;

  -- 쪽지가 맞는 것을 확인한 **뒤에** 번호를 본다. 아무 쪽지로나 번호를 시험하지 못한다
  v_chk := store_code_check(r.bookstore_id, p_code);
  IF v_chk = 'locked' THEN RETURN qr_fail('번호를 여러 번 잘못 넣어서 잠시 잠겼어요. 10분 뒤에 다시 해주세요'); END IF;
  IF v_chk <> 'ok'    THEN RETURN qr_fail('확인 번호가 달라요'); END IF;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '이름 없음')
    INTO v_who FROM profiles p WHERE p.id = r.user_id;
  SELECT ro.title INTO v_routine FROM routines ro WHERE ro.id = r.routine_id;
  SELECT b.name   INTO v_store   FROM bookstores b WHERE b.id = r.bookstore_id;

  RETURN jsonb_build_object('ok', true, 'who', v_who, 'routine', v_routine,
    'bookstore', v_store, 'bookstore_id', r.bookstore_id,
    'left_sec', GREATEST(0, EXTRACT(epoch FROM (r.expires_at - now()))::int));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION redeem_qr_lookup(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION redeem_qr_lookup(text, text) TO anon, authenticated;

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
-- 만들어지기만 한 것은 85·87 에서 당했다. 몸통이 실제로 도는지까지 본다.
-- (맞는 번호로 부르므로 틀린 횟수가 남지 않는다)
SELECT
  (SELECT count(*) FROM store_names())                                         AS 책방수,
  (SELECT store_code_check(c.bookstore_id, c.code)
     FROM bookstore_codes c LIMIT 1)                                           AS 번호검사_ok여야,
  (SELECT store_login(c.bookstore_id, btrim(c.code)) ->> 'ok'
     FROM bookstore_codes c LIMIT 1)                                           AS 로그인_true여야,
  (SELECT length(replace(gen_random_uuid()::text, '-', '')))                   AS 열쇠길이_32여야,
  (SELECT prorettype::regtype::text FROM pg_proc
    WHERE proname = 'redeem_qr_lookup')                                        AS 조회반환_jsonb여야,
  (SELECT count(*) FROM store_attempts WHERE failed > 0)                       AS 남은_틀린횟수_0이어야;
