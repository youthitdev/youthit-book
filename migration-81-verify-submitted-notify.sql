-- 한끗독서 마이그레이션 81
-- 청소년이 확인 서류를 내면 운영진에게 알린다
--
-- 【78 만으로는 모자랐다】 78 은 「가입」을 잡는다. 그런데 가입은 아직
--   운영진이 할 일이 없는 순간이고, 진짜 「승인해 주세요」인 순간은
--   서류를 내는 때다. 그때가 비어 있어서 승인이 하루씩 밀렸다.
--
-- 【언제 보내나】 verify_status 가 pending 으로 들어설 때만.
--   ① 처음 내는 경우 (none → pending)
--   ② 반려됐던 사람이 다시 내는 경우 (rejected → pending)
--   ③ 이미 pending 인데 사진만 다시 올리는 경우는 보내지 않는다 —
--      서류를 세 번 갈아 올리면 세 번 울릴 이유가 없다
--
-- 겸사겸사 78 의 링크에 #verify 를 붙인다. 관리자 화면이 이제 주소의 #탭 을
-- 읽으므로, 다른 탭을 보고 있다가 눌러도 청소년 확인으로 간다.

-- ── 1. 서류를 냈다 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION on_verify_submitted() RETURNS trigger AS $$
DECLARE a uuid; v_who text; v_again boolean; v_doc text;
BEGIN
  IF NEW.verify_status IS DISTINCT FROM 'pending' THEN RETURN NEW; END IF;
  IF OLD.verify_status IS NOT DISTINCT FROM 'pending' THEN RETURN NEW; END IF;

  v_again := (OLD.verify_status = 'rejected');
  v_who   := COALESCE(NULLIF(btrim(NEW.name), ''), '이름 없음');
  v_doc   := CASE WHEN COALESCE(btrim(NEW.verify_doc_path), '') <> ''
                  THEN '서류 있음' ELSE '서류 없음' END;

  FOR a IN SELECT * FROM admin_user_ids() LOOP
    CONTINUE WHEN a = NEW.id;
    PERFORM notify_push(a,
      CASE WHEN v_again THEN '서류를 다시 냈어요 📄'
                        ELSE '청소년 확인 서류가 왔어요 📄' END,
      v_who || ' · ' || COALESCE(NULLIF(btrim(NEW.region), ''), '지역 없음')
            || ' · ' || v_doc,
      '/youthit-book/admin.html#verify');
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- 알림이 터져서 서류 제출이 막히면 안 된다
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS profiles_verify_notify ON profiles;
CREATE TRIGGER profiles_verify_notify AFTER UPDATE OF verify_status ON profiles
  FOR EACH ROW EXECUTE FUNCTION on_verify_submitted();

-- ── 2. 가입 알림도 제 탭으로 가게 ──────────────────────
CREATE OR REPLACE FUNCTION on_profile_created() RETURNS trigger AS $$
DECLARE a uuid; v_who text; v_where text;
BEGIN
  IF COALESCE(NEW.role, 'youth') <> 'youth' THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = NEW.id) THEN RETURN NEW; END IF;

  v_who := COALESCE(NULLIF(btrim(NEW.name), ''), '이름 없음');
  IF COALESCE(btrim(NEW.nick), '') <> '' AND NEW.nick <> NEW.name THEN
    v_who := v_who || '(' || btrim(NEW.nick) || ')';
  END IF;
  v_where := COALESCE(NULLIF(btrim(NEW.region), ''), '지역 없음');

  FOR a IN SELECT * FROM admin_user_ids() LOOP
    PERFORM notify_push(a, '새 청소년이 가입했어요 🌱',
      v_who || ' · ' || v_where || ' · 확인해 주세요',
      '/youthit-book/admin.html#verify');
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'on_verify_submitted')     AS 서류함수,
       (SELECT count(*) FROM pg_trigger
         WHERE tgname = 'profiles_verify_notify' AND NOT tgisinternal)          AS 방아쇠,
       (SELECT count(*) FROM auth.users
         WHERE email IN ('dev@youthvoice.or.kr','yv@youthvoice.or.kr'))         AS 받을사람,
       (SELECT count(*) FROM profiles WHERE verify_status = 'pending')          AS 지금대기중;
