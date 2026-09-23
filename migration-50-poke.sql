-- ────────────────────────────────────────────────────────────────────
-- 50. 콕 찌르기
--
--   끗짱이 오늘 아직 안 읽은 아이에게 「한 장 어때요」를 보낸다.
--
--   ⚠️ 이 기능은 잘못 만들면 재촉 장치가 된다. 세 가지로 묶는다.
--     · 하루에 한 번. 같은 아이에게 두 번 못 보낸다
--     · 오늘 이미 인증한 아이에게는 못 보낸다
--     · 자기가 맡은 루틴의 아이에게만
--
--   문구에 숫자를 넣지 않는다. 「3일째 안 했어요」는 찌르기가 아니라 추궁이다.
-- ────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS nudges (
  from_id    uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  to_id      uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  routine_id bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  day        date   NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Seoul')::date),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (from_id, to_id, routine_id, day)
);
COMMENT ON TABLE nudges IS '끗짱이 콕 찌른 기록. 하루 한 번을 지키는 데 쓴다';

ALTER TABLE nudges ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS nudge_mine ON nudges;
-- 아이는 「누가 나를 몇 번 찔렀나」를 볼 이유가 없다. 알림으로 이미 받았다
CREATE POLICY nudge_mine ON nudges FOR SELECT TO authenticated
  USING (from_id = auth.uid() OR is_admin());

CREATE OR REPLACE FUNCTION poke(p_routine bigint, p_user uuid) RETURNS void AS $$
DECLARE v_lead uuid; v_title text; v_me text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF p_user = auth.uid() THEN RAISE EXCEPTION '자기 자신은 찌를 수 없어요'; END IF;

  SELECT led_by, title INTO v_lead, v_title FROM routines WHERE id = p_routine;
  IF v_lead IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION '맡은 루틴의 아이에게만 보낼 수 있어요';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM routine_participants
                  WHERE routine_id = p_routine AND user_id = p_user AND status = 'approved') THEN
    RAISE EXCEPTION '이 루틴에 참여 중인 사람이 아니에요';
  END IF;

  IF EXISTS (SELECT 1 FROM certifications
              WHERE routine_id = p_routine AND user_id = p_user
                AND cert_date = (now() AT TIME ZONE 'Asia/Seoul')::date) THEN
    RAISE EXCEPTION '오늘 이미 읽었어요';
  END IF;

  INSERT INTO nudges (from_id, to_id, routine_id) VALUES (auth.uid(), p_user, p_routine);
  -- 위에서 걸리면 오늘 이미 보낸 것이다
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION '오늘은 이미 보냈어요';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 알림은 트리거로 뺀다. 넣는 일과 보내는 일이 한 함수에 있으면
-- 알림이 실패했을 때 「보냈나 안 보냈나」를 알 수 없다
CREATE OR REPLACE FUNCTION on_nudge() RETURNS trigger AS $$
DECLARE v_title text; v_me text;
BEGIN
  SELECT title INTO v_title FROM routines WHERE id = NEW.routine_id;
  SELECT COALESCE(nick, name) INTO v_me FROM profiles WHERE id = NEW.from_id;
  -- 숫자도 「며칠째」도 넣지 않는다. 찌르기지 추궁이 아니다
  PERFORM notify_push(NEW.to_id,
    COALESCE(v_me, '끗짱') || ' 끗짱이 콕 찔렀어요 👉',
    COALESCE(v_title, '루틴') || ' · 오늘 한 장 어때요?',
    '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS nudge_notify ON nudges;
CREATE TRIGGER nudge_notify AFTER INSERT ON nudges
  FOR EACH ROW EXECUTE FUNCTION on_nudge();

REVOKE EXECUTE ON FUNCTION poke(bigint, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION poke(bigint, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT 'nudges' AS 표,
       (SELECT count(*) FROM information_schema.columns WHERE table_name='nudges') AS 칸,
       (SELECT count(*) FROM pg_trigger WHERE tgname='nudge_notify') AS 트리거,
       pg_get_function_identity_arguments('poke'::regproc) AS 함수인자;
