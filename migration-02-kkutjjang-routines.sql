-- 한끗독서 마이그레이션 02
-- 끗짱이 앱에서 직접 루틴을 만들 수 있게 함
--
-- 【설계】 루틴 기획은 서점(끗짱)이, 예산은 유스보이스가 맡는다.
--   그래서 끗짱은 루틴을 만들 수 있되, 인증당 적립액은 관리자가 정한
--   상한을 넘길 수 없다. 적립액이 곧 후원금이라 여기가 뚫리면 예산이
--   통제되지 않는다.

-- ────────────────────────────────────────────────────────────────────
-- 1. 적립액 상한 설정
-- ────────────────────────────────────────────────────────────────────
ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS max_amount_per_cert int NOT NULL DEFAULT 1500;

COMMENT ON COLUMN dokseo_settings.max_amount_per_cert IS
  '끗짱이 루틴을 만들 때 고를 수 있는 인증당 적립액의 상한(원). 관리자는 제한 없음';


-- ────────────────────────────────────────────────────────────────────
-- 2. 끗짱이 만든 루틴의 값 검증
--    - led_by 는 무조건 본인으로 (남의 이름으로 루틴을 못 만들게)
--    - 적립액은 상한 이하로
--    - status 는 recruit 으로 시작 (진행·종료 전환은 별도)
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
DECLARE
  v_role text;
  v_max  int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role IS DISTINCT FROM 'kkutjjang' THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  NEW.led_by := auth.uid();

  SELECT max_amount_per_cert INTO v_max FROM dokseo_settings WHERE id = 1;
  IF COALESCE(NEW.amount_per_cert, 0) > COALESCE(v_max, 0) THEN
    RAISE EXCEPTION '인증당 적립액은 %원을 넘을 수 없습니다', v_max;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.status := 'recruit';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_check ON routines;
CREATE TRIGGER routines_check BEFORE INSERT OR UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION check_routine_write();


-- ────────────────────────────────────────────────────────────────────
-- 3. RLS — 끗짱에게 자기 루틴에 대한 권한 부여
--    (기존 routines_admin 정책은 그대로 두고 추가한다. 정책은 OR로 합쳐진다)
-- ────────────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS routines_kkutjjang_insert ON routines;
CREATE POLICY routines_kkutjjang_insert ON routines FOR INSERT
  WITH CHECK (
    led_by = auth.uid()
    AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'kkutjjang')
  );

DROP POLICY IF EXISTS routines_kkutjjang_update ON routines;
CREATE POLICY routines_kkutjjang_update ON routines FOR UPDATE
  USING (led_by = auth.uid())
  WITH CHECK (led_by = auth.uid());
