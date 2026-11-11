-- 한끗독서 마이그레이션 158
-- 끗짱 가입 둘째 화면의 「어떤 마음으로」「활동 경험」을 가입과 함께 끗짱 신청서에 넣는다 (2026-11-11 요청)
--
-- 【바뀌는 것】 가입할 때 자동으로 만드는 끗짱 신청서(pending)의 동기(motive)와 경험(experience) 칸에,
--   가입 화면에서 적은 값(k_motive · k_experience)을 넣는다. 안 적었으면(청소년이 만 19세를 넘겨 올라온 경우 등)
--   옛 문구 그대로다. 나머지는 157 의 handle_new_user 와 같다.
--   운영진의 끗짱 승인 화면은 그대로 — 같은 칸을 읽는다.
--
-- ⚠️ 103·157 뒤에 돌린다. 여러 번 돌려도 된다. 안 돌려도 가입은 된다(동기·경험이 신청서에 안 들어갈 뿐).

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

    -- 어른(끗짱을 골랐거나 만 19세 초과)은 가입과 동시에 끗짱 승인 대기로
    v_age := age_years(v_birth);
    IF v_age IS NOT NULL AND v_age BETWEEN 14 AND 100
       AND (m->>'join_role' = 'kkut' OR v_age > 19) THEN
      v_aff := COALESCE(NULLIF(btrim(m->>'school_status'), ''), '없음');
      INSERT INTO kkut_applications (user_id, age, affiliation, region, contact, intro, motive, experience, status, applied_at)
      VALUES (NEW.id, v_age, v_aff,
              COALESCE(NULLIF(btrim(m->>'region'), ''), '미상'),
              COALESCE(NULLIF(btrim(m->>'phone'), ''), '운영진이 따로 확인'),
              '가입할 때 끗짱을 골랐어요. 구글폼 신청 여부를 확인해 주세요',
              -- 가입 둘째 화면에서 적은 것 (없으면 옛 문구)
              COALESCE(NULLIF(left(btrim(COALESCE(m->>'k_motive', '')), 300), ''), '가입 시 자동으로 올라온 신청이에요'),
              NULLIF(left(btrim(COALESCE(m->>'k_experience', '')), 300), ''),
              'pending', now())
      ON CONFLICT (user_id) DO NOTHING;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 여기서 막으면 가입 자체가 통째로 막힌다 (한끗루틴에서 겪었다)
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 1 (가입 함수가 k_motive 를 읽는다)
SELECT count(*) AS 가입함수_1이어야 FROM pg_proc WHERE proname = 'handle_new_user' AND prosrc LIKE '%k_motive%';
