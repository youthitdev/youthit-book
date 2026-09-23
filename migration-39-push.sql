-- ────────────────────────────────────────────────────────────────────
-- 39. 푸시 알림
--
--   한끗루틴에서 돌고 있는 구조를 그대로 가져왔다.
--     push_subscriptions  기기별 구독 (한 사람이 폰·노트북 여러 대일 수 있다)
--     notifications       앱 안 알림함. 푸시를 못 받거나 놓쳐도 여기엔 남는다
--     notify_push()       둘 다 한다 — 표에 남기고, Edge Function 을 부른다
--
--   푸시가 실패해도 알림함은 남는다. 그 반대는 안 된다.
--   배너는 그 순간 못 보면 사라지기 때문이다.
--
--   ⚠️ 이 파일을 돌리기 전에 service_role 키를 금고에 넣어야 한다:
--        SELECT vault.create_secret('<service_role 키>', 'sr_key_for_push');
--      안 넣어도 이 파일은 그냥 돈다. 알림함만 쌓이고 푸시는 조용히 건너뛴다.
-- ────────────────────────────────────────────────────────────────────

-- pg_net 은 DB 가 바깥으로 요청을 보내는 데 쓴다. 이미 켜져 있으면 그냥 지나간다
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- ── 1. 구독 ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS push_subscriptions (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id    uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  endpoint   text NOT NULL UNIQUE,
  p256dh     text NOT NULL,
  auth       text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_subs_user_idx ON push_subscriptions(user_id);

ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ps_select ON push_subscriptions;
DROP POLICY IF EXISTS ps_insert ON push_subscriptions;
DROP POLICY IF EXISTS ps_update ON push_subscriptions;
DROP POLICY IF EXISTS ps_delete ON push_subscriptions;
CREATE POLICY ps_select ON push_subscriptions FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY ps_insert ON push_subscriptions FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
CREATE POLICY ps_update ON push_subscriptions FOR UPDATE TO authenticated USING (user_id = auth.uid());
CREATE POLICY ps_delete ON push_subscriptions FOR DELETE TO authenticated USING (user_id = auth.uid());

-- ── 2. 앱 안 알림함 ────────────────────────────────────
CREATE TABLE IF NOT EXISTS notifications (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id    uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  title      text NOT NULL,
  body       text,
  link       text,
  read       boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notif_user_idx ON notifications(user_id, created_at DESC);

ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notif_select ON notifications;
DROP POLICY IF EXISTS notif_update ON notifications;
CREATE POLICY notif_select ON notifications FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY notif_update ON notifications FOR UPDATE TO authenticated USING (user_id = auth.uid());

-- ── 3. 보내는 함수 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION notify_push(
  p_user uuid, p_title text, p_body text DEFAULT '', p_url text DEFAULT NULL
) RETURNS void AS $$
DECLARE
  sr_key text;
  v_url  text := COALESCE(p_url, '/youthit-book/app.html');
BEGIN
  IF p_user IS NULL THEN RETURN; END IF;

  INSERT INTO notifications(user_id, title, body, link) VALUES (p_user, p_title, p_body, v_url);

  SELECT decrypted_secret INTO sr_key FROM vault.decrypted_secrets WHERE name = 'sr_key_for_push';
  IF sr_key IS NULL THEN RETURN; END IF;   -- 키가 없으면 알림함만. 조용히 넘어간다

  PERFORM net.http_post(
    url     := 'https://qvpahwvihvkasrznboaa.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer ' || sr_key),
    body    := jsonb_build_object('user_id', p_user, 'title', p_title,
                                  'body', p_body, 'url', v_url, 'from_db', true)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION notify_push(uuid, text, text, text) FROM PUBLIC, anon, authenticated;

-- ── 4. 루틴 참여 승인 · 반려 ───────────────────────────
CREATE OR REPLACE FUNCTION on_participant_decided() RETURNS trigger AS $$
DECLARE t text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status NOT IN ('approved', 'rejected') THEN RETURN NEW; END IF;
  SELECT title INTO t FROM routines WHERE id = NEW.routine_id;
  IF NEW.status = 'approved' THEN
    PERFORM notify_push(NEW.user_id, '루틴에 참여하게 됐어요 📚',
      COALESCE(t, '루틴') || ' · 오늘부터 한 장씩 같이 읽어요',
      '/youthit-book/app.html?routine=' || NEW.routine_id);
  ELSE
    PERFORM notify_push(NEW.user_id, '이번 루틴은 함께하지 못했어요',
      COALESCE(t, '루틴') || ' · 다른 루틴은 계속 열려요');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS parts_notify ON routine_participants;
CREATE TRIGGER parts_notify AFTER UPDATE ON routine_participants
  FOR EACH ROW EXECUTE FUNCTION on_participant_decided();

-- ── 5. 청소년 확인 · 끗짱 승인 ─────────────────────────
-- 둘 다 profiles 가 바뀌는 일이라 한 트리거에서 본다
CREATE OR REPLACE FUNCTION on_profile_decided() RETURNS trigger AS $$
BEGIN
  IF NEW.verify_status IS DISTINCT FROM OLD.verify_status THEN
    IF NEW.verify_status = 'approved' THEN
      PERFORM notify_push(NEW.id, '청소년 확인이 끝났어요 ✅',
        '이제 루틴에 참여할 수 있어요', '/youthit-book/app.html?tab=home');
    ELSIF NEW.verify_status = 'rejected' THEN
      PERFORM notify_push(NEW.id, '서류를 다시 올려주세요',
        COALESCE(NEW.verify_reason, '확인이 어려웠어요'), '/youthit-book/app.html?tab=my');
    END IF;
  END IF;

  IF NEW.can_lead AND NOT OLD.can_lead THEN
    PERFORM notify_push(NEW.id, '끗짱이 되셨어요 💪',
      '이제 루틴을 만들 수 있어요', '/youthit-book/app.html?tab=home');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS profiles_notify ON profiles;
CREATE TRIGGER profiles_notify AFTER UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION on_profile_decided();

-- 끗짱 반려는 profiles 가 안 바뀌므로 신청서 쪽에서 본다
CREATE OR REPLACE FUNCTION on_kkut_decided() RETURNS trigger AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF NEW.status = 'rejected' THEN
    PERFORM notify_push(NEW.user_id, '끗짱 신청을 다시 봐주세요',
      COALESCE(NEW.reject_reason, '내용을 조금 더 적어주세요'), '/youthit-book/app.html');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS kkut_notify ON kkut_applications;
CREATE TRIGGER kkut_notify AFTER UPDATE ON kkut_applications
  FOR EACH ROW EXECUTE FUNCTION on_kkut_decided();

-- ── 6. 루틴 열림 · 반려 (끗짱에게) ─────────────────────
CREATE OR REPLACE FUNCTION on_routine_decided() RETURNS trigger AS $$
BEGIN
  IF NEW.led_by IS NULL THEN RETURN NEW; END IF;
  IF OLD.status = 'pending' AND NEW.status = 'recruit' THEN
    PERFORM notify_push(NEW.led_by, '루틴이 열렸어요 🎉',
      NEW.title || ' · 이제 아이들이 신청할 수 있어요',
      '/youthit-book/app.html?routine=' || NEW.id);
  ELSIF NEW.status = 'pending'
    AND NEW.reject_reason IS DISTINCT FROM OLD.reject_reason
    AND COALESCE(btrim(NEW.reject_reason), '') <> '' THEN
    PERFORM notify_push(NEW.led_by, '루틴을 조금 고쳐주세요',
      NEW.reject_reason, '/youthit-book/app.html?routine=' || NEW.id);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_notify ON routines;
CREATE TRIGGER routines_notify AFTER UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION on_routine_decided();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT tgname AS 트리거, c.relname AS 표
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE tgname IN ('parts_notify','profiles_notify','kkut_notify','routines_notify')
 ORDER BY 1;
