-- 한끗독서 마이그레이션 32
-- 끗짱이 만든 루틴은 운영진이 열어줘야 보인다
--
-- 끗짱 승인을 받았다고 해서 그 사람이 만드는 루틴까지 다 맞는 건 아니다.
-- 기간이 이상하거나, 인증 방법이 아이에게 무리하거나, 제목이 부적절할 수 있다.
-- 아이들이 신청하기 전에 한 번 보고 연다.
--
-- 운영진이 직접 만든 루틴은 바로 열린다. 자기가 만든 걸 자기가 승인할 이유가 없다.

-- ── 1. 상태에 '승인 대기'를 더한다 ─────────────────────
-- ⚠️ 컬럼은 함수보다 먼저 만든다. plpgsql 은 만들 때 컬럼을 검사하지 않아서,
--    순서가 뒤면 함수는 멀쩡히 만들어지고 실제로 부를 때 터진다 (17 에서 당했다)
ALTER TABLE routines ADD COLUMN IF NOT EXISTS reject_reason text;
COMMENT ON COLUMN routines.reject_reason IS '운영진이 돌려보낸 이유. 끗짱 화면에 보인다';

ALTER TABLE routines DROP CONSTRAINT IF EXISTS routines_status_check;
ALTER TABLE routines ADD CONSTRAINT routines_status_check
  CHECK (status IN ('pending', 'recruit', 'active', 'done'));

COMMENT ON COLUMN routines.status IS
  'pending 승인 대기 · recruit 모집 중 · active 진행 중 · done 종료';

-- ── 2. 끗짱이 만들면 pending 으로 굳힌다 ────────────────
-- 화면에서 status 를 recruit 로 보내도 여기서 되돌린다. 화면만 믿으면 뚫린다
CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
BEGIN
  -- SQL 편집기에는 auth.uid() 가 없다
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;

  IF NOT is_approved_kkut() THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.led_by := auth.uid();
    NEW.status := 'pending';            -- 운영진이 열어줘야 보인다
  ELSE
    -- 끗짱이 스스로 승인 상태를 바꾸지 못하게 막는다.
    -- 아직 대기 중이면 계속 대기, 열린 뒤에는 모집·진행·종료만 오간다
    IF OLD.status = 'pending' AND NEW.status <> 'pending' THEN
      NEW.status := 'pending';
    END IF;
    IF OLD.status <> 'pending' AND NEW.status = 'pending' THEN
      NEW.status := OLD.status;
    END IF;
    -- 돌려받은 뒤 고쳐서 다시 내는 것이다. 사유를 지워 다시 대기로 만든다
    IF OLD.status = 'pending' THEN NEW.reject_reason := NULL; END IF;
    NEW.led_by := OLD.led_by;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_check ON routines;
CREATE TRIGGER routines_check BEFORE INSERT OR UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION check_routine_write();

-- ── 3. 대기 중인 루틴은 남에게 안 보인다 ────────────────
-- 아이가 "곧 열릴 루틴" 을 미리 보고 기다리다 반려되면 더 안 좋다
DROP POLICY IF EXISTS routines_read ON routines;
CREATE POLICY routines_read ON routines FOR SELECT
  USING (status <> 'pending' OR led_by = auth.uid() OR is_admin());

-- ── 4. 운영진이 열고 닫는다 ────────────────────────────
CREATE OR REPLACE FUNCTION decide_routine(p_id bigint, p_open boolean, p_reason text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_status text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  SELECT status INTO v_status FROM routines WHERE id = p_id;
  IF v_status IS NULL THEN RAISE EXCEPTION '루틴을 찾을 수 없습니다'; END IF;
  IF v_status <> 'pending' THEN RAISE EXCEPTION '이미 처리된 루틴입니다'; END IF;

  IF p_open THEN
    UPDATE routines SET status = 'recruit' WHERE id = p_id;
  ELSE
    IF COALESCE(btrim(p_reason), '') = '' THEN
      RAISE EXCEPTION '반려 사유를 적어주세요';
    END IF;
    -- 지우지 않는다. 끗짱이 고쳐서 다시 낼 수 있어야 하고, 지우면
    -- ON DELETE CASCADE 로 딸린 것들이 같이 사라진다
    UPDATE routines SET status = 'pending', reject_reason = btrim(p_reason) WHERE id = p_id;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION decide_routine(bigint, boolean, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION decide_routine(bigint, boolean, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ↓ 지금 루틴들. 기존 루틴은 그대로 두었다 (이미 아이들이 참여 중이다)
SELECT id AS 루틴, title AS 이름, status AS 상태, led_by IS NOT NULL AS 끗짱있음
  FROM routines ORDER BY id;
