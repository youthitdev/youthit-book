-- 한끗독서 마이그레이션 106
-- 인증에 좋아요가 달리면 올린 사람에게 알린다
--
-- 【누구에게】 그 인증을 올린 사람 한 명. 본인이 누른 것은 알리지 않는다.
--
-- 【눌렀다 뗐다 해도 한 번만】 취소하고 다시 누르면 INSERT 가 또 들어온다. 그때마다 울리면 장난에
--   쓰인다. 같은 사람이 같은 인증에 보낸 같은 알림이 **하루 안에** 이미 있으면 보내지 않는다.
--
-- 【알림이 터져도 좋아요는 저장된다】 EXCEPTION 으로 막아 둔다.
--
-- ⚠️ 39(notify_push) · 105(cert_likes) 뒤에 돌린다. 이미 돌렸어도 다시 돌려도 된다.

CREATE OR REPLACE FUNCTION on_like_notify() RETURNS trigger AS $$
DECLARE v_author uuid; v_rid bigint; v_title text; v_who text; v_body text;
BEGIN
  SELECT c.user_id, c.routine_id INTO v_author, v_rid FROM certifications c WHERE c.id = NEW.cert_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;

  SELECT r.title INTO v_title FROM routines r WHERE r.id = v_rid;
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  v_body := COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '친구') || '님이 좋아해요';

  -- 하루 안에 같은 알림이 이미 갔으면 다시 보내지 않는다 (눌렀다 뗐다 대비)
  IF EXISTS (SELECT 1 FROM notifications n
              WHERE n.user_id = v_author AND n.title = '인증에 ❤️가 달렸어요'
                AND n.body = v_body
                AND n.link = '/youthit-book/app.html?tab=cert&routine=' || v_rid
                AND n.created_at > now() - interval '1 day') THEN
    RETURN NEW;
  END IF;

  PERFORM notify_push(v_author, '인증에 ❤️가 달렸어요', v_body,
    '/youthit-book/app.html?tab=cert&routine=' || v_rid);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS likes_notify ON cert_likes;
CREATE TRIGGER likes_notify AFTER INSERT ON cert_likes
  FOR EACH ROW EXECUTE FUNCTION on_like_notify();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 방아쇠가 붙었는지만 본다. 알림을 실제로 보내지 않는다. 기대: 1, 1
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'likes_notify' AND NOT tgisinternal) AS 방아쇠_1이어야,
       (SELECT count(*) FROM pg_proc    WHERE proname = 'on_like_notify')                   AS 함수_1이어야;
