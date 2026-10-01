-- 한끗독서 마이그레이션 70
-- 운영진이 끗짱을 정하면 본인에게 알린다
--
-- 운영진이 루틴을 만들고 끗짱을 임명할 수 있게 된다(화면은 관리자 쪽).
-- 서버는 이미 열려 있었다 — check_routine_write() 가 is_admin() 이면
-- 통째로 비켜준다. 없던 건 화면과, 이 알림 하나다.
--
-- 【왜 알려야 하나】 자기 이름으로 루틴이 생겼는데 본인만 모르는 건
--   말이 안 된다. 아이들은 그 사람을 보고 들어온다.
--
-- 【본인이 만들면 안 간다】 끗짱이 제 루틴을 만든 건 알릴 일이 아니다.

CREATE OR REPLACE FUNCTION on_routine_lead_assigned() RETURNS trigger AS $$
DECLARE v_old uuid;
BEGIN
  v_old := CASE WHEN TG_OP = 'UPDATE' THEN OLD.led_by ELSE NULL END;
  IF NEW.led_by IS NULL OR NEW.led_by IS NOT DISTINCT FROM v_old THEN RETURN NEW; END IF;
  IF NEW.led_by = auth.uid() THEN RETURN NEW; END IF;

  PERFORM notify_push(NEW.led_by, '루틴을 맡게 됐어요 📚',
    COALESCE(NEW.title, '루틴') || ' · 운영진이 끗짱으로 정했어요',
    '/youthit-book/app.html?routine=' || NEW.id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_lead_notify ON routines;
CREATE TRIGGER routines_lead_notify AFTER INSERT OR UPDATE OF led_by ON routines
  FOR EACH ROW EXECUTE FUNCTION on_routine_lead_assigned();

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT tgname AS 방아쇠 FROM pg_trigger
 WHERE tgname = 'routines_lead_notify' AND NOT tgisinternal;
