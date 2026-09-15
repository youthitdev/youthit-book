-- 한끗독서 마이그레이션 10
-- 09 정정: '그 자리에서 찍은 사진만'은 강제가 아니라 기본값이다
--
-- 09에서 트리거가 camera_only 를 true 로 못 박아 끗짱이 끌 수 없게 만들었다.
-- 기본은 켜두되 끗짱이 해제할 수 있어야 한다. 강제 대입만 걷어낸다.
-- 컬럼 기본값 true 는 그대로 둔다 (만들기 화면에서도 체크된 상태로 시작).

CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
DECLARE
  v_role   text;
  v_amount int;
BEGIN
  -- 적립액은 누가 만들든 설정값으로 붙인다. 관리자도 예외 없음
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

COMMENT ON COLUMN routines.camera_only IS
  '기본 true. 끗짱이 끌 수 있다. 켜져 있으면 인증 사진을 그 자리에서 찍어야 한다';
