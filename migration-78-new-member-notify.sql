-- 한끗독서 마이그레이션 78
-- 새 청소년이 가입하면 운영진에게 바로 알린다
--
-- 【왜 필요한가】 확인이 끝나야 루틴에 들어갈 수 있다. 그런데 운영진은
--   누가 가입했는지를 관리자 화면을 열어봐야 안다. 하루가 밀리면 아이는
--   「신청했는데 아무 일도 안 일어나는 앱」을 하루 더 보고 있다.
--
-- 【왜 가입 때인가】 서류를 내는 순간이 아니라 가입하는 순간에 보낸다.
--   서류를 못 구해 헤매는 아이가 제일 먼저 떨어져 나가는데, 그 아이는
--   「서류 제출」 알림을 영영 안 울린다. 가입만으로 한 번은 눈에 띄어야 한다.
--
-- 【운영진이 둘뿐이라 목록을 만들지 않는다】 is_admin() 이 이메일로 판정하므로
--   같은 이메일로 auth.users 를 뒤져 uid 를 얻는다. 운영진이 늘면 여기와
--   is_admin() 두 곳을 같이 고친다 — 한 곳만 고치면 알림이 조용히 안 간다.

-- ── 1. 운영진 uid ──────────────────────────────────────
-- auth.users 를 읽으므로 SECURITY DEFINER. 아무에게도 열지 않는다
CREATE OR REPLACE FUNCTION admin_user_ids() RETURNS SETOF uuid AS $$
  SELECT id FROM auth.users
   WHERE email IN ('dev@youthvoice.or.kr', 'yv@youthvoice.or.kr');
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION admin_user_ids() FROM PUBLIC, anon, authenticated;

-- ── 2. 가입하면 보낸다 ─────────────────────────────────
CREATE OR REPLACE FUNCTION on_profile_created() RETURNS trigger AS $$
DECLARE a uuid; v_who text; v_where text;
BEGIN
  -- 어른은 끗짱 승인 쪽에서 따로 본다
  IF COALESCE(NEW.role, 'youth') <> 'youth' THEN RETURN NEW; END IF;

  v_who := COALESCE(NULLIF(btrim(NEW.name), ''), '이름 없음');
  IF COALESCE(btrim(NEW.nick), '') <> '' AND NEW.nick <> NEW.name THEN
    v_who := v_who || '(' || btrim(NEW.nick) || ')';
  END IF;
  v_where := COALESCE(NULLIF(btrim(NEW.region), ''), '지역 없음');

  FOR a IN SELECT * FROM admin_user_ids() LOOP
    CONTINUE WHEN a = NEW.id;        -- 운영진이 제 계정을 만든 거면 보내지 않는다
    PERFORM notify_push(a,
      '새 청소년이 가입했어요 🌱',
      v_who || ' · ' || v_where || ' · 확인해 주세요',
      '/youthit-book/admin.html');
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- 알림이 터져서 가입이 막히면 안 된다. 알림은 있으면 좋은 것이고 가입은 아니다
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS profiles_new_notify ON profiles;
CREATE TRIGGER profiles_new_notify AFTER INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION on_profile_created();

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'admin_user_ids')      AS 운영진함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'on_profile_created')  AS 알림함수,
       (SELECT count(*) FROM pg_trigger
         WHERE tgname = 'profiles_new_notify' AND NOT tgisinternal)         AS 방아쇠,
       (SELECT count(*) FROM auth.users
         WHERE email IN ('dev@youthvoice.or.kr','yv@youthvoice.or.kr'))     AS 받을사람;
