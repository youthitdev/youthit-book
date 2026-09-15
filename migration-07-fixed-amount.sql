-- 한끗독서 마이그레이션 07
-- 인증 1회당 적립액을 운영진이 정하는 고정값으로
--
-- 【배경】 끗짱은 아무나 될 수 있다. 그런데 지금은 끗짱이 루틴을 만들면서
--   적립액을 직접 정한다. 상한(1,500원)만 걸려 있어서, 가입만 하면
--   루틴 하나에 최대 18만원(8명 × 15일 × 1,500원)의 후원금을 걸 수 있다.
--   적립액은 곧 후원금이므로 예산은 유스보이스가 쥐는 게 맞다.
--
--   그래서 끗짱은 적립액을 고르지 않는다. 운영진이 정한 한 값이 자동으로 붙는다.
--
-- 【중요】 routines.amount_per_cert 컬럼은 그대로 둔다.
--   적립금은 '인증 수 × 그 루틴의 단가'로 계산하기 때문에, 설정값을 나중에
--   바꿨을 때 이미 끝난 루틴의 적립금까지 소급해서 변하면 안 된다.
--   루틴을 만드는 시점의 값을 그 루틴에 굳혀 둔다.

ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS amount_per_cert int NOT NULL DEFAULT 1300;

COMMENT ON COLUMN dokseo_settings.amount_per_cert IS
  '인증 1회당 적립액(원). 끗짱이 루틴을 만들면 이 값이 자동으로 붙는다';

COMMENT ON COLUMN dokseo_settings.max_amount_per_cert IS
  '[미사용] 끗짱이 적립액을 직접 고르던 시절의 상한. migration-07 에서 고정값으로 바뀌며 쓰이지 않는다';

CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
DECLARE
  v_role   text;
  v_amount int;
BEGIN
  -- 적립액은 누가 만들든 설정값으로 붙인다. 관리자도 예외 없음.
  -- (컬럼 기본값이 0이라, 예외를 두면 적립금 0원짜리 루틴이 조용히 생긴다)
  IF TG_OP = 'INSERT' THEN
    SELECT amount_per_cert INTO v_amount FROM dokseo_settings WHERE id = 1;
    NEW.amount_per_cert := COALESCE(v_amount, 1300);
  ELSE
    -- 수정할 때는 만들 당시의 단가를 지킨다. 적립금이 소급 변동하면 안 된다
    NEW.amount_per_cert := OLD.amount_per_cert;
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
