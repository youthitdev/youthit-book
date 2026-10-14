-- 한끗독서 마이그레이션 132
-- 어른은 가입하면 곧바로 「끗짱 승인 대기」로 올라간다 (2026-10-14 사용자)
--
-- 【정한 것】 어른은 무조건 끗짱으로만 가입한다. 가입한 뒤 유스보이스가 승인해 주면 된다.
--
-- 【무엇이 문제였나】 끗짱으로 가입한 어른도 가입 때 역할이 일단 「청소년」으로 저장된다(끗짱 권한은 운영진이 열어 주는 것이라서).
--   그래서 신청서가 아직 없는 끗짱 희망자는 운영진의 「청소년 확인」 명단에 청소년과 섞여 「아직 안 냄」으로 보였다 (만 56세 등).
--
-- 【고침】
--   1) 가입할 때 「끗짱」을 골랐거나 만 20세를 넘었으면, 가입과 동시에 끗짱 신청서를 **대기(pending)** 로 만든다.
--      → 「청소년 확인」 명단에서 빠지고 「끗짱 승인」의 심사 대기에 올라온다. 운영진에게는 「끗짱 신청이 들어왔어요」 알림이 간다.
--      → 신청서의 소속·지역·연락처·나이는 가입할 때 적은 것을 옮겨 담는다. 「소개」 칸에는 구글폼 신청 여부를 확인하라고 적는다.
--      → 권한(can_lead)은 승인 전에는 열리지 않는다. 앱에서는 「끗짱 승인을 기다리고 있어요」 화면이 나온다.
--   2) 이미 가입해 있는, 같은 조건인데 신청서가 없는 사람도 한 번 대기로 올린다 (운영진·탈퇴한 회원·이미 끗짱인 사람은 뺀다).
--   3) 끗짱 희망자의 가입에는 「새 청소년이 가입했어요」 알림을 보내지 않는다 (위의 끗짱 신청 알림이 대신 간다).
--
-- 【그대로인 것】 청소년으로 가입하는 만 14~20세, 화면의 가입 제한(청소년은 만 20세까지)은 그대로다.
--
-- ⚠️ 41·80·117·121 뒤에 돌린다. 여러 번 돌려도 된다. 2) 때문에 기존 어른 수만큼 운영진에게 「끗짱 신청이 들어왔어요」 알림이 한꺼번에 간다.

-- ── 1) 가입할 때 ───────────────────────────────────────
CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger AS $$
DECLARE m jsonb := NEW.raw_user_meta_data; v_birth date; v_age int; v_aff text;
BEGIN
  BEGIN
    INSERT INTO profiles (id, name, nick, role, region,
                          school_status, marketing_ok, policy_agreed_at)
    VALUES (NEW.id,
            COALESCE(NULLIF(btrim(m->>'name'), ''), '이름없음'),
            NULLIF(btrim(m->>'nick'), ''),
            'youth',
            m->>'region',
            NULLIF(btrim(m->>'school_status'), ''),
            COALESCE((m->>'marketing_ok')::boolean, false),
            COALESCE(NULLIF(m->>'policy_agreed_at', '')::timestamptz, now()))
    ON CONFLICT (id) DO NOTHING;

    -- 번호와 생년월일은 남에게 보이면 안 되는 것들이라 따로 둔다
    v_birth := NULLIF(m->>'birth_date', '')::date;
    INSERT INTO profiles_private (id, phone, birth_date)
    VALUES (NEW.id, NULLIF(btrim(m->>'phone'), ''), v_birth)
    ON CONFLICT (id) DO UPDATE
       SET phone      = COALESCE(EXCLUDED.phone, profiles_private.phone),
           birth_date = COALESCE(EXCLUDED.birth_date, profiles_private.birth_date);

    -- 어른(끗짱을 골랐거나 만 20세 초과)은 가입과 동시에 끗짱 승인 대기로
    v_age := age_years(v_birth);
    IF v_age IS NOT NULL AND v_age BETWEEN 14 AND 100
       AND (m->>'join_role' = 'kkut' OR v_age > 20) THEN
      v_aff := COALESCE(NULLIF(btrim(m->>'school_status'), ''), '없음');
      INSERT INTO kkut_applications (user_id, age, affiliation, region, contact, intro, motive, status, applied_at)
      VALUES (NEW.id, v_age, v_aff,
              COALESCE(NULLIF(btrim(m->>'region'), ''), '미상'),
              COALESCE(NULLIF(btrim(m->>'phone'), ''), '운영진이 따로 확인'),
              '가입할 때 끗짱을 골랐어요. 구글폼 신청 여부를 확인해 주세요',
              '가입 시 자동으로 올라온 신청이에요', 'pending', now())
      ON CONFLICT (user_id) DO NOTHING;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 여기서 막으면 가입 자체가 통째로 막힌다 (한끗루틴에서 겪었다)
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 3) 끗짱 희망자의 가입에는 「새 청소년」 알림을 보내지 않는다 (117 판에 한 줄만 더한다) ──
CREATE OR REPLACE FUNCTION on_profile_created() RETURNS trigger AS $$
DECLARE a uuid; v_who text; v_where text;
BEGIN
  IF COALESCE(NEW.role, 'youth') <> 'youth' THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.admin_user_ids() a WHERE a = NEW.id) THEN RETURN NEW; END IF;
  -- 끗짱 희망자: 끗짱 신청 알림(80)이 대신 간다
  IF EXISTS (SELECT 1 FROM auth.users u WHERE u.id = NEW.id AND u.raw_user_meta_data->>'join_role' = 'kkut') THEN
    RETURN NEW;
  END IF;

  v_who := COALESCE(NULLIF(btrim(NEW.name), ''), '이름 없음');
  IF COALESCE(btrim(NEW.nick), '') <> '' AND NEW.nick <> NEW.name THEN
    v_who := v_who || '(' || btrim(NEW.nick) || ')';
  END IF;
  v_where := COALESCE(NULLIF(btrim(NEW.region), ''), '지역 없음');

  FOR a IN SELECT * FROM public.admin_user_ids() LOOP
    PERFORM public.notify_push(a, '새 청소년이 가입했어요 🌱',
      v_who || ' · ' || v_where || ' · 확인해 주세요',
      '/youthit-book/admin.html#verify');
  END LOOP;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  BEGIN
    INSERT INTO public.notify_errors(fn, msg) VALUES ('on_profile_created', SQLERRM);
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ── 2) 이미 가입해 있는 사람 ───────────────────────────
INSERT INTO kkut_applications (user_id, age, affiliation, region, contact, intro, motive, status, applied_at)
SELECT p.id, age_years(pp.birth_date),
       COALESCE(NULLIF(btrim(p.school_status), ''), '없음'),
       COALESCE(NULLIF(btrim(p.region), ''), '미상'),
       COALESCE(NULLIF(btrim(pp.phone), ''), '운영진이 따로 확인'),
       '가입할 때 끗짱을 골랐거나 만 20세를 넘어 자동으로 올라왔어요. 구글폼 신청 여부를 확인해 주세요',
       '가입 시 자동으로 올라온 신청이에요', 'pending', now()
  FROM profiles p
  JOIN profiles_private pp ON pp.id = p.id
  JOIN auth.users u ON u.id = p.id
 WHERE COALESCE(p.role, 'youth') = 'youth'
   AND NOT COALESCE(p.can_lead, false)
   AND p.withdrawn_at IS NULL
   AND p.name <> '탈퇴한 회원'
   AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id)
   AND NOT EXISTS (SELECT 1 FROM kkut_applications k WHERE k.user_id = p.id)
   AND age_years(pp.birth_date) BETWEEN 14 AND 100
   AND (u.raw_user_meta_data->>'join_role' = 'kkut' OR age_years(pp.birth_date) > 20)
ON CONFLICT (user_id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 함수 새 판 1 / 아래 「남은 어른」은 0 (청소년 명단에 어른이 안 남았다)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'handle_new_user'
          AND pg_get_functiondef(oid) LIKE '%kkut_applications%')                               AS 새_판_1이어야,
       (SELECT count(*) FROM kkut_applications WHERE status = 'pending')                         AS 끗짱_심사_대기,
       (SELECT count(*) FROM profiles p JOIN profiles_private pp ON pp.id = p.id
         WHERE COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
           AND p.withdrawn_at IS NULL AND age_years(pp.birth_date) > 20
           AND NOT EXISTS (SELECT 1 FROM kkut_applications k WHERE k.user_id = p.id)
           AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id))                     AS 남은_어른_0이어야;
