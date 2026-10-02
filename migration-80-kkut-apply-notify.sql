-- 한끗독서 마이그레이션 80
-- 끗짱 신청이 들어오면 운영진에게 알린다
--
-- 【78 과 무엇이 다른가】 78 은 「가입」을 잡는다. 끗짱은 가입이 아니라
--   가입한 뒤 신청서를 내는 것이라 자리가 다르다.
--
-- 【언제 보내나】 심사 대기로 들어설 때만. 세 가지를 가려야 한다
--   ① 새 신청 (INSERT, pending)
--   ② 반려됐던 사람의 재신청 (UPDATE, rejected → pending)
--   ③ 운영진이 직접 세운 것(migration-79)은 보내지 않는다 —
--      그건 승인된 채로 들어오고, 누른 사람이 운영진 본인이다
--
-- ⚠️ 78 의 admin_user_ids() 를 그대로 쓴다. 운영진이 늘면
--    is_admin() · admin_user_ids() 두 곳을 같이 고쳐야 한다.

CREATE OR REPLACE FUNCTION on_kkut_application() RETURNS trigger AS $$
DECLARE a uuid; v_name text; v_again boolean;
BEGIN
  IF NEW.status <> 'pending' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.status = 'pending' THEN RETURN NEW; END IF;

  v_again := (TG_OP = 'UPDATE');
  SELECT name INTO v_name FROM profiles WHERE id = NEW.user_id;
  v_name := COALESCE(NULLIF(btrim(v_name), ''), '이름 없음');

  FOR a IN SELECT * FROM admin_user_ids() LOOP
    PERFORM notify_push(a,
      CASE WHEN v_again THEN '끗짱 신청이 다시 들어왔어요 📖'
                        ELSE '끗짱 신청이 들어왔어요 📖' END,
      v_name || ' · ' || NEW.age || '세 · ' || NEW.affiliation,
      '/youthit-book/admin.html#kkut');
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- 알림이 터져서 신청이 막히면 안 된다
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS kkut_app_notify ON kkut_applications;
CREATE TRIGGER kkut_app_notify AFTER INSERT OR UPDATE ON kkut_applications
  FOR EACH ROW EXECUTE FUNCTION on_kkut_application();

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'on_kkut_application')  AS 알림함수,
       (SELECT count(*) FROM pg_trigger
         WHERE tgname = 'kkut_app_notify' AND NOT tgisinternal)              AS 방아쇠,
       (SELECT count(*) FROM pg_proc WHERE proname = 'admin_user_ids')       AS 운영진함수,
       (SELECT count(*) FROM auth.users
         WHERE email IN ('dev@youthvoice.or.kr','yv@youthvoice.or.kr'))      AS 받을사람;
