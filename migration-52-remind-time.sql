-- ────────────────────────────────────────────────────────────────────
-- 52. 독서 리마인더를 각자 시각으로
--
--   40 번에서 만든 리마인더는 저녁 8시 고정이었다. 학원 가는 아이와
--   새벽에 읽는 아이에게 같은 시각을 밀어 넣는 셈이다.
--
--   사람마다 시각을 고르고 끌 수 있게 한다.
--
--   ⚠️ 시계는 30분마다 돈다. 「고른 시각이 지났고 오늘 아직 안 보냈으면」
--      보내는 식이라, 8시 15분으로 정해도 8시 30분에 한 번 간다.
--      분 단위로 맞추려면 1분마다 돌려야 하는데 그럴 값이 아니다.
-- ────────────────────────────────────────────────────────────────────

ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS remind_on      boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS remind_at      time    NOT NULL DEFAULT '20:00',
  ADD COLUMN IF NOT EXISTS last_remind_on date;

COMMENT ON COLUMN profiles.remind_at      IS '매일 독서 리마인더 시각 (한국 시간)';
COMMENT ON COLUMN profiles.last_remind_on IS '그날 이미 보냈는지. 하루 한 번을 지킨다';

-- ── 본인이 못 바꾸는 칸에 넣지 않는다 ──────────────────
-- remind_* 는 본인이 정하는 값이다. check_profile_write 는 건드리지 않는다.
-- 다만 last_remind_on 은 시계가 찍는 값이라 사람이 손대면 안 된다
CREATE OR REPLACE FUNCTION check_profile_write() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.id         := OLD.id;
    NEW.role       := OLD.role;
    NEW.can_lead   := OLD.can_lead;
    NEW.created_at := OLD.created_at;
    NEW.verified_at := OLD.verified_at;
    NEW.verify_kind := OLD.verify_kind;
    NEW.last_remind_on := OLD.last_remind_on;   -- 시계가 찍는 값
    IF OLD.policy_agreed_at IS NOT NULL THEN NEW.policy_agreed_at := OLD.policy_agreed_at; END IF;
    IF NEW.verify_status <> OLD.verify_status THEN
      IF OLD.verify_status IN ('none', 'rejected') AND NEW.verify_status = 'pending' THEN
        NEW.verify_reason := NULL;
      ELSE
        NEW.verify_status := OLD.verify_status;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 각자 시각에 보낸다 ─────────────────────────────────
CREATE OR REPLACE FUNCTION remind_today_cert() RETURNS int AS $$
DECLARE
  n int := 0; r record;
  d date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  t time := (now() AT TIME ZONE 'Asia/Seoul')::time;
BEGIN
  FOR r IN
    SELECT DISTINCT p.id
      FROM profiles p
      JOIN routine_participants rp ON rp.user_id = p.id AND rp.status = 'approved'
      JOIN routines ro ON ro.id = rp.routine_id
     WHERE p.remind_on
       AND p.remind_at <= t                       -- 고른 시각이 지났고
       AND p.last_remind_on IS DISTINCT FROM d    -- 오늘 아직 안 보냈고
       AND ro.status = 'active'
       AND d BETWEEN ro.start_date AND ro.end_date
       AND NOT EXISTS (SELECT 1 FROM certifications c
                        WHERE c.routine_id = ro.id AND c.user_id = p.id
                          AND c.cert_date = d)
  LOOP
    -- 며칠 빠졌는지, 남들은 몇 명 했는지는 넣지 않는다
    PERFORM notify_push(r.id, '오늘 한 장, 아직이에요 📖',
      '한 장이면 오늘 몫은 끝이에요', '/youthit-book/app.html?tab=cert');
    UPDATE profiles SET last_remind_on = d WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION remind_today_cert() FROM PUBLIC, anon, authenticated;

-- ── 시계를 30분마다로 ──────────────────────────────────
SELECT cron.unschedule('dokseo-today-cert')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-today-cert');
SELECT cron.schedule('dokseo-today-cert', '*/30 * * * *', 'SELECT remind_today_cert()');

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT jobname AS 이름, schedule AS 시각 FROM cron.job WHERE jobname LIKE 'dokseo-%'
 UNION ALL
SELECT 'profiles.' || column_name, column_default
  FROM information_schema.columns
 WHERE table_name = 'profiles' AND column_name IN ('remind_on','remind_at','last_remind_on')
 ORDER BY 1;
