-- ────────────────────────────────────────────────────────────────────
-- 51. 루틴에 후원 기업 이름
--
--   썸네일 오른쪽 아래에 「○○기업과 함께」를 띄운다.
--
--   ⚠️ 끗짱이 적는 값이 아니다. 기업 이름은 약속이 오간 뒤에야 붙는 것이고,
--      아무나 적을 수 있으면 「○○은행과 함께」 같은 루틴이 생긴다.
--      운영진만 넣을 수 있게 트리거로 막는다.
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE routines ADD COLUMN IF NOT EXISTS sponsor_name text;
COMMENT ON COLUMN routines.sponsor_name IS
  '이 루틴을 후원한 기업·기관. 운영진만 넣는다 (check_routine_write)';

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
    NEW.sponsor_name := NULL;           -- 기업 이름은 스스로 붙일 수 없다
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
    NEW.led_by       := OLD.led_by;
    NEW.sponsor_name := OLD.sponsor_name;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'routines' AND column_name = 'sponsor_name') AS 칸생김,
       (SELECT prosrc LIKE '%NEW.sponsor_name := OLD.sponsor_name%'
          FROM pg_proc WHERE proname = 'check_routine_write')            AS 끗짱은_못바꿈;
