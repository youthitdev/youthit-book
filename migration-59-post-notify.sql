-- 한끗독서 마이그레이션 59
-- 끗짱이 오늘 글을 올리면 아이들에게 바로 알린다
--
-- 【왜 꼭 트리거인가】 이 알림은 있으면 좋은 게 아니라 **없으면 안 되는 것**이다.
--   글이 안 올라온 날은 아이가 인증 자체를 못 한다 — 알림이 곧 「오늘 읽을 게
--   생겼다」는 신호다. 앱에서 보내면 끗짱이 글만 올리고 앱을 닫거나 전파가
--   끊긴 순간 알림이 사라진다. 글이 저장되는 그 자리에서 같이 나가야 한다.
--   (앱은 send-push 를 부를 권한도 없다 — 운영진 키만 된다)
--
-- 【고쳐 올릴 땐 안 보낸다】 INSERT 에만 걸었다. 앱은 upsert 라 같은 날 다시
--   올리면 UPDATE 로 들어간다 — 오타 고칠 때마다 울리면 안 된다.

CREATE OR REPLACE FUNCTION on_post_shared() RETURNS trigger AS $$
DECLARE v_title text; v_body text; u record;
BEGIN
  SELECT title INTO v_title FROM routines WHERE id = NEW.routine_id;
  v_body := COALESCE(v_title, '루틴')
            || COALESCE(' · ' || NULLIF(btrim(NEW.title), ''), '');

  -- 끗짱 자신에게는 안 보낸다. 방금 올린 사람이다
  FOR u IN SELECT p.user_id FROM routine_participants p
            WHERE p.routine_id = NEW.routine_id
              AND p.status = 'approved'
              AND p.user_id <> NEW.user_id
  LOOP
    PERFORM notify_push(u.user_id, '오늘 읽을 글이 올라왔어요 📖', v_body,
      '/youthit-book/app.html?routine=' || NEW.routine_id);
  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS posts_notify ON routine_posts;
CREATE TRIGGER posts_notify AFTER INSERT ON routine_posts
  FOR EACH ROW EXECUTE FUNCTION on_post_shared();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT tgname AS 트리거, c.relname AS 표, p.proname AS 함수,
       CASE WHEN t.tgtype & 4 > 0 THEN 'INSERT' ELSE '?' END AS 언제
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc  p ON p.oid = t.tgfoid
 WHERE tgname = 'posts_notify';
