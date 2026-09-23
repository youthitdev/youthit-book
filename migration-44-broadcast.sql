-- ────────────────────────────────────────────────────────────────────
-- 44. 운영진이 직접 보내는 알림
--
--   지금까지 알림은 전부 「무슨 일이 일어나면」 자동으로 나갔다.
--   운영진이 「내일 모임 있어요」 같은 걸 보낼 길이 없었다.
--
--   예약을 같이 넣는다. 저녁 8시에 보내려고 운영진이 밤에 앉아 있을 수는 없다.
--   5분마다 돌면서 때가 된 것을 보낸다 — 최대 5분 늦을 수 있다.
--
--   ⚠️ 39·40 을 먼저 돌려야 한다 (notify_push · pg_cron · 금고).
-- ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS scheduled_notifications (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  title      text NOT NULL,
  body       text,
  target     text NOT NULL CHECK (target IN ('all', 'routine')),
  routine_id bigint REFERENCES routines(id) ON DELETE CASCADE,
  send_at    timestamptz NOT NULL,
  sent_at    timestamptz,
  sent_count int,
  created_by uuid REFERENCES auth.users ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE scheduled_notifications IS '운영진이 예약해 둔 알림. 보낸 뒤에도 기록으로 남는다';

ALTER TABLE scheduled_notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sn_admin ON scheduled_notifications;
CREATE POLICY sn_admin ON scheduled_notifications FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

-- ── 때가 된 것을 보낸다 ────────────────────────────────
CREATE OR REPLACE FUNCTION send_scheduled_notifications() RETURNS int AS $$
DECLARE n record; sr_key text; cnt int := 0;
BEGIN
  SELECT decrypted_secret INTO sr_key FROM vault.decrypted_secrets WHERE name = 'sr_key_for_push';
  -- 금고에 키가 없으면 보낼 수 없다. 여기서 sent_at 을 찍으면 안 된다 —
  -- 찍어 버리면 키를 넣은 뒤에도 영영 안 나간다
  IF sr_key IS NULL THEN RETURN 0; END IF;

  FOR n IN SELECT * FROM scheduled_notifications
            WHERE sent_at IS NULL AND send_at <= now()
            ORDER BY send_at
  LOOP
    PERFORM net.http_post(
      url     := 'https://qvpahwvihvkasrznboaa.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'Authorization', 'Bearer ' || sr_key),
      body    := CASE WHEN n.target = 'all'
        THEN jsonb_build_object('title', n.title, 'body', n.body, 'target', 'all')
        ELSE jsonb_build_object('title', n.title, 'body', n.body,
                                'target', 'routine', 'routine_id', n.routine_id)
      END);
    UPDATE scheduled_notifications SET sent_at = now() WHERE id = n.id;
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION send_scheduled_notifications() FROM PUBLIC, anon, authenticated;

-- ── 시계 ───────────────────────────────────────────────
SELECT cron.unschedule('dokseo-scheduled-notif')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-scheduled-notif');
SELECT cron.schedule('dokseo-scheduled-notif', '*/5 * * * *', 'SELECT send_scheduled_notifications()');

-- ── 몇 명에게 갈지 미리 세어 준다 ──────────────────────
-- 「전체」가 몇 명인지 모르고 보내면 운영진이 손이 떨린다
CREATE OR REPLACE FUNCTION push_reach(p_routine bigint DEFAULT NULL)
RETURNS TABLE (people int) AS $$
  SELECT count(DISTINCT s.user_id)::int
    FROM push_subscriptions s
   WHERE is_admin()
     AND (p_routine IS NULL
          OR s.user_id IN (SELECT rp.user_id FROM routine_participants rp
                            WHERE rp.routine_id = p_routine AND rp.status = 'approved'));
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION push_reach(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION push_reach(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT jobname AS 이름, schedule AS 시각, active AS 켜짐
  FROM cron.job WHERE jobname LIKE 'dokseo-%' ORDER BY 1;
