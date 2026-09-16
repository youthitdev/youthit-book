-- 한끗독서 마이그레이션 25
-- check_routine_write() 도 SQL 편집기에서 통과시킨다
--
-- 【문제】 SQL 편집기에서 UPDATE routines SET status='done' WHERE id=1; 을 하면
--     ERROR: 끗짱만 루틴을 만들 수 있습니다
--   auth.uid() 가 NULL 이라 is_admin() 이 false 가 되고,
--   profiles 조회도 NULL 이 나와 역할 검사에 걸린다.
--
--   migration-21 에서 check_profile_write / check_kkut_application 에는
--   'auth.uid() IS NULL 이면 서버 쪽' 조건을 넣었는데 여기만 빠뜨렸다.
--
-- 【안전한가】 익명은 routines 를 쓸 수 없다.
--   routines_admin        FOR ALL USING (is_admin())        → 익명은 false
--   routines_kkutjjang_insert WITH CHECK (led_by = auth.uid() AND …)
--                          → auth.uid() 가 NULL 이면 led_by = NULL 이 NULL 이라 거부
--   UPDATE 를 익명에게 여는 정책은 없다.
--   그래서 auth.uid() IS NULL 로 여기까지 오는 건 SQL 편집기·서버뿐이다.

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
    NEW.amount_per_cert := OLD.amount_per_cert;
  END IF;

  -- auth.uid() 가 NULL = SQL 편집기·서버 쪽 (익명은 정책이 막아 여기 못 온다)
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;

  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role IS DISTINCT FROM 'kkutjjang' THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  IF NOT is_approved_kkut() THEN
    RAISE EXCEPTION '끗짱 승인을 받아야 루틴을 만들 수 있습니다';
  END IF;

  NEW.led_by := auth.uid();
  IF TG_OP = 'INSERT' THEN NEW.status := 'recruit'; END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_check ON routines;
CREATE TRIGGER routines_check BEFORE INSERT OR UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION check_routine_write();
