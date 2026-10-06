-- 한끗독서 마이그레이션 84
-- 아이가 루틴에 들어오면 끗짱에게 알린다
--
-- 【승인이 아니라 환영이다】 마이그레이션 16 에서 끗짱 승인을 없앴다.
--   아이가 신청하면 곧바로 참여가 된다. 그래서 이 알림은 「처리하세요」가
--   아니라 「새 친구가 왔어요」다.
--   문지기가 없어진 만큼 이게 더 필요해졌다 — 끗짱이 모르고 지나가면
--   그 아이는 아무에게도 환영받지 못한 채 혼자 첫 인증을 올린다.
--
-- 【혹시 남아 있을 pending 도 챙긴다】 운영진이 손으로 넣거나 옛 기록이
--   pending 으로 들어오면 그때는 「확인이 필요해요」로 말을 바꾼다.
--   같은 트리거 안에서 갈라 쓴다 — 트리거를 둘로 두면 하나만 고치게 된다.
--
-- 【끗짱이 없는 루틴은 운영진에게】 운영진이 직접 보는 루틴이다.
--   아무에게도 안 가는 것보다 낫다.
--
-- ⚠️ 78 을 먼저 돌려야 한다 (admin_user_ids). 39 도 (notify_push).

CREATE OR REPLACE FUNCTION on_participant_joined() RETURNS trigger AS $$
DECLARE
  v_title  text;
  v_lead   uuid;
  v_who    text;
  v_head   text;
  v_body   text;
  a        uuid;
BEGIN
  SELECT r.title, r.led_by INTO v_title, v_lead
    FROM routines r WHERE r.id = NEW.routine_id;

  -- 끗짱이 제 루틴에 참여한 것은 알릴 일이 아니다
  IF v_lead IS NOT NULL AND v_lead = NEW.user_id THEN RETURN NEW; END IF;

  -- 이름은 profiles 에서. 닉네임이 따로 있으면 그걸 쓴다 —
  -- 끗짱이 루틴 안에서 보는 이름이 닉네임이라, 실명을 보내면 누군지 모른다
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '새 친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;

  IF COALESCE(NEW.status, 'approved') = 'pending' THEN
    v_head := '확인이 필요한 신청이 왔어요 🙋';
    v_body := COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '새 친구');
  ELSE
    v_head := '새 친구가 들어왔어요 🙋';
    v_body := COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '새 친구') || ' · 인사해 주세요';
  END IF;

  IF v_lead IS NOT NULL THEN
    PERFORM notify_push(v_lead, v_head, v_body,
      '/youthit-book/app.html?routine=' || NEW.routine_id);
  ELSE
    -- 끗짱이 아직 없는 루틴. 운영진이 보고 있다
    FOR a IN SELECT * FROM admin_user_ids() LOOP
      IF a = NEW.user_id THEN CONTINUE; END IF;
      PERFORM notify_push(a, v_head, v_body,
        '/youthit-book/app.html?routine=' || NEW.routine_id);
    END LOOP;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- 알림이 터져서 참여가 막히면 안 된다. 알림은 있으면 좋은 것이고 참여는 아니다
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS parts_join_notify ON routine_participants;
CREATE TRIGGER parts_join_notify AFTER INSERT ON routine_participants
  FOR EACH ROW EXECUTE FUNCTION on_participant_joined();

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc
         WHERE proname = 'on_participant_joined')                     AS 알림함수,
       (SELECT count(*) FROM pg_trigger
         WHERE tgname = 'parts_join_notify' AND NOT tgisinternal)     AS 방아쇠,
       (SELECT count(*) FROM routines
         WHERE status = 'active' AND led_by IS NOT NULL)              AS 끗짱있는_루틴,
       (SELECT count(*) FROM routines
         WHERE status = 'active' AND led_by IS NULL)                  AS 운영진이보는_루틴;
