-- 한끗독서 마이그레이션 92
-- 사장님 화면에 아이의 「만 나이」를 보인다
--
-- 【왜 필요한가】 사장님은 닉네임과 시각만 보고 「지금 눈앞에 있는 이 아이가 맞나」를
--   가늠해야 했다. 닉네임이 같거나 낯설면 헷갈린다. 만 나이는 눈앞의 사람과 맞춰
--   보기 쉬운 한 줄이다.
--
-- 【생년월일은 내보내지 않는다】 profiles_private 에는 본인과 운영진만 읽을 수 있는
--   생년월일이 있다. 사장님 화면은 SECURITY DEFINER 함수를 거치므로 **계산한 만 나이
--   하나만** 돌려준다. 날짜가 나가는 길은 열지 않는다.
--
-- 【두 군데】 ① 청구 목록 store_pending  ② QR 을 찍었을 때 보이는 한 건 redeem_qr_lookup
--   (아이가 눈앞에 있는 순간이라 여기가 더 쓸모 있다)
--
-- ⚠️ store_pending 은 돌려주는 칸이 늘어서 CREATE OR REPLACE 가 안 된다. 먼저 지운다.
--   칸 이름을 age 가 아니라 kid_age 로 한 건, plpgsql 의 RETURNS TABLE 칸 이름이
--   함수 안에서 변수가 되어 내장 함수 age() 와 헷갈릴 수 있어서다.
-- ⚠️ 85·86·91 뒤에 돌린다.

-- ── 1. 청구 목록 ───────────────────────────────────────
DROP FUNCTION IF EXISTS store_pending(text);

CREATE OR REPLACE FUNCTION store_pending(p_key text)
RETURNS TABLE (
  id bigint, who text, kid_age int, came_at timestamptz,
  code_ok boolean, store_amount int, submitted boolean, settled boolean
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
         g.status = 'settled'
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

-- ── 2. QR 로 열린 한 건 ────────────────────────────────
-- 91 의 본문 그대로에 만 나이 한 줄만 더했다. 돌려주는 모양이 jsonb 라 CREATE OR REPLACE 로 된다
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
  IF v_chk <> 'ok'    THEN RETURN qr_fail('확인 번호가 달라요'); END IF;

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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- store_pending 은 실제로 불러서 몸통이 도는지 본다 (85 에서 없는 칸을 읽다 당했다).
-- lookup 은 쪽지가 있어야 부를 수 있어서, 새로 더한 나이 계산 식만 따로 돌려 본다.
SELECT
  (SELECT 'kid_age' = ANY(proargnames) FROM pg_proc WHERE proname = 'store_pending') AS 칸추가_true여야,
  (SELECT count(*) FROM store_pending((SELECT access_key FROM bookstore_keys LIMIT 1))) AS 목록_돌아가나,
  (SELECT age_years(birth_date) FROM profiles_private WHERE birth_date IS NOT NULL LIMIT 1) AS 나이_식_돌아가나,
  (SELECT prorettype::regtype::text FROM pg_proc WHERE proname = 'redeem_qr_lookup') AS 조회반환_jsonb여야;
