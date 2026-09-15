-- 한끗독서 마이그레이션 09
-- 인증 사진은 그 자리에서 찍은 것만 — 루틴 옵션이 아니라 고정값
--
-- 【배경】 한끗독서의 인증은 "지금 읽고 있는 순간"을 담는 것이다.
--   갤러리에 있던 사진을 올릴 수 있으면 그 전제가 무너진다.
--   끗짱이 끌 수 있는 옵션이 아니라 서비스의 기본 규칙으로 둔다.

ALTER TABLE routines ALTER COLUMN camera_only SET DEFAULT true;
UPDATE routines SET camera_only = true WHERE camera_only = false;

COMMENT ON COLUMN routines.camera_only IS
  '항상 true. 인증 사진은 그 자리에서 찍은 것만 받는다 (migration-09에서 고정)';

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

  NEW.camera_only := true;   -- 고정값

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
