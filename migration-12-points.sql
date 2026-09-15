-- 한끗독서 마이그레이션 12
-- 적립금(원) → 포인트 + 교환권
--
-- 【바뀌는 것】
--   인증 1회 = 20포인트. 300포인트가 모이면 2만원 이하 책 1권 교환권이 나온다.
--   (20p × 15일 = 300p. 기존 1,300원 × 15일 = 19,500원과 같은 값이라 예산은 그대로)
--
-- 【포인트는 계정에 쌓인다 — 중요】
--   루틴이 끝나도 포인트가 사라지지 않는다. 280포인트로 끝나면 다음 루틴에서
--   20포인트만 더 채우면 교환권이 나온다. 하루 빠진 게 전부를 잃는 게 아니라
--   조금 미뤄지는 일이 되도록 하기 위해서다. 고립·은둔 청소년에게
--   '하루 빠지면 끝'은 이탈 방아쇠가 된다.

-- ── 1. 설정
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_cert    int NOT NULL DEFAULT 20;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_voucher int NOT NULL DEFAULT 300;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS voucher_max_amount int NOT NULL DEFAULT 20000;

COMMENT ON COLUMN dokseo_settings.points_per_cert    IS '인증 1회당 포인트. 루틴을 만들 때 이 값이 붙는다';
COMMENT ON COLUMN dokseo_settings.points_per_voucher IS '교환권 1장에 필요한 포인트';
COMMENT ON COLUMN dokseo_settings.voucher_max_amount IS '교환권 1장으로 살 수 있는 책값 상한(원)';
COMMENT ON COLUMN dokseo_settings.amount_per_cert    IS '[미사용] 포인트 전환(migration-12) 이전의 인증 1회당 적립액';

-- ── 2. 루틴
ALTER TABLE routines ADD COLUMN IF NOT EXISTS points_per_cert int NOT NULL DEFAULT 20;
COMMENT ON COLUMN routines.points_per_cert IS '인증 1회당 포인트. 만들 때 설정값이 굳어진다';
COMMENT ON COLUMN routines.amount_per_cert IS '[미사용] 포인트 전환(migration-12) 이전 값';

-- ── 3. 내 포인트 · 교환권
--    본인 것 아니면 못 본다 (예전 dokseo_balance 는 아무 uuid 나 물어볼 수 있었다)
CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_points int; v_per int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  -- 루틴을 가리지 않고 계정 전체로 센다
  SELECT COALESCE(sum(r.points_per_cert), 0) INTO v_points
    FROM certifications c JOIN routines r ON r.id = c.routine_id
   WHERE c.user_id = v_u;

  SELECT points_per_voucher INTO v_per FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 300), 1);

  -- 정산 대기 중인 구매도 교환권을 이미 쓴 것으로 본다 (중복 사용 방지)
  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',      v_points,
    'per_voucher', v_per,
    'earned',      v_earned,
    'used',        v_used,
    'left',        GREATEST(0, v_earned - v_used),
    'to_next',     v_per - (v_points % v_per)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ── 4. 책 구매는 쓸 수 있는 교환권이 있어야
CREATE OR REPLACE FUNCTION check_book_purchase_insert() RETURNS trigger AS $$
DECLARE v_left int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status       := 'pending';
  NEW.amount       := NULL;
  NEW.receipt_url  := NULL;
  NEW.settled_by   := NULL;
  NEW.settled_at   := NULL;
  NEW.photo_public := false;

  v_left := (dokseo_points(NEW.user_id) ->> 'left')::int;
  IF COALESCE(v_left, 0) <= 0 THEN
    RAISE EXCEPTION '아직 쓸 수 있는 교환권이 없습니다';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 5. 정산 상한은 잔액이 아니라 교환권 한도
CREATE OR REPLACE FUNCTION settle_book_purchase(
  p_purchase_id bigint,
  p_amount      int,
  p_receipt_url text DEFAULT NULL,
  p_note        text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_left int := p_amount; v_take int; v_charge record;
  v_allocs jsonb := '[]'::jsonb; v_pool int;
  v_user uuid; v_routine bigint; v_cap int; v_per int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION '정산 금액이 올바르지 않습니다'; END IF;

  SELECT user_id, routine_id INTO v_user, v_routine
    FROM book_purchases WHERE id = p_purchase_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 대기 상태의 건이 아닙니다 (id=%)', p_purchase_id;
  END IF;

  SELECT voucher_max_amount, points_per_voucher INTO v_cap, v_per
    FROM dokseo_settings WHERE id = 1;
  v_cap := COALESCE(v_cap, 20000);
  v_per := GREATEST(COALESCE(v_per, 300), 1);

  IF p_amount > v_cap THEN
    RAISE EXCEPTION '교환권 한도를 넘습니다 (한도 %원 / 입력 %원)', v_cap, p_amount;
  END IF;

  SELECT COALESCE(sum(remaining_amount), 0) INTO v_pool FROM charges WHERE remaining_amount > 0;
  IF v_pool < p_amount THEN
    RAISE EXCEPTION '도서기금 잔액이 부족합니다 (잔액 %원 / 필요 %원)', v_pool, p_amount;
  END IF;

  FOR v_charge IN
    SELECT id, remaining_amount FROM charges
    WHERE remaining_amount > 0 ORDER BY charged_at, id FOR UPDATE
  LOOP
    EXIT WHEN v_left <= 0;
    v_take := LEAST(v_charge.remaining_amount, v_left);

    INSERT INTO consumption_allocations (purchase_id, charge_id, amount)
    VALUES (p_purchase_id, v_charge.id, v_take);

    UPDATE charges
       SET remaining_amount = remaining_amount - v_take,
           status       = CASE WHEN remaining_amount - v_take = 0 THEN 'completed' ELSE status END,
           completed_at = CASE WHEN remaining_amount - v_take = 0 THEN now() ELSE completed_at END
     WHERE id = v_charge.id;

    v_allocs := v_allocs || jsonb_build_object('charge_id', v_charge.id, 'amount', v_take);
    v_left := v_left - v_take;

    -- 읽은 날 = 그 구매가 뜻하는 일수(교환권 포인트 ÷ 루틴 단가)를, 후원이 댄 몫만큼
    INSERT INTO completion_events (charge_id, students_count, purchases_count, reading_days, total_amount, message)
    SELECT c.id,
           count(DISTINCT p.user_id),
           count(DISTINCT p.id),
           COALESCE(sum( (a.amount::numeric / NULLIF(p.amount, 0))
                         * (v_per::numeric / NULLIF(r.points_per_cert, 0)) ), 0)::int,
           c.book_fund_amount,
           NULL
      FROM charges c
      JOIN consumption_allocations a ON a.charge_id = c.id
      JOIN book_purchases p ON p.id = a.purchase_id
      JOIN routines r ON r.id = p.routine_id
     WHERE c.id = v_charge.id AND c.remaining_amount = 0
     GROUP BY c.id, c.book_fund_amount
    ON CONFLICT (charge_id) DO NOTHING;
  END LOOP;

  UPDATE book_purchases
     SET status = 'settled', amount = p_amount,
         receipt_url = COALESCE(p_receipt_url, receipt_url),
         note = COALESCE(p_note, note),
         settled_by = auth.uid(), settled_at = now()
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('purchase_id', p_purchase_id, 'amount', p_amount, 'allocations', v_allocs);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 6. 루틴을 만들 때 붙는 값도 포인트로
CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
DECLARE
  v_role   text;
  v_points int;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT points_per_cert INTO v_points FROM dokseo_settings WHERE id = 1;
    NEW.points_per_cert := COALESCE(v_points, 20);
  ELSE
    -- 만들 당시의 단가를 지킨다. 이미 쌓인 포인트가 소급 변동하면 안 된다
    NEW.points_per_cert := OLD.points_per_cert;
  END IF;

  IF is_admin() THEN RETURN NEW; END IF;

  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role IS DISTINCT FROM 'kkutjjang' THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  NEW.led_by := auth.uid();
  IF TG_OP = 'INSERT' THEN NEW.status := 'recruit'; END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_check ON routines;
CREATE TRIGGER routines_check BEFORE INSERT OR UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION check_routine_write();

-- ── 7. 정리
DROP FUNCTION IF EXISTS dokseo_balance(uuid, bigint);

REVOKE EXECUTE ON FUNCTION dokseo_points(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points(uuid) TO authenticated;
