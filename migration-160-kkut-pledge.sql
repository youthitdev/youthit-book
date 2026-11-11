-- 한끗독서 마이그레이션 160
-- 끗짱 가입 때 「청소년 보호 수칙」 동의를 받아 신청서에 남긴다 (2026-11-11 요청: 구글 신청 폼을 없애고 가입으로 합친다)
--
-- 【바뀌는 것】 가입 둘째 화면에서 동의한 때(k_pledge)를 끗짱 신청서의 pledge_at 에 서버 시계로 넣는다.
--   신청서 소개 칸의 옛 문구(「구글폼 신청 여부를 확인해 주세요」)에서 구글폼 말을 뺀다.
--   나머지는 158 의 handle_new_user 와 같다.
--
-- ⚠️ 103·158 뒤에 돌린다. 여러 번 돌려도 된다. 안 돌려도 가입은 된다(동의 시각이 신청서에 안 남을 뿐).

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
      INSERT INTO kkut_applications (user_id, age, affiliation, region, contact, intro, motive, experience, pledge_at, status, applied_at)
      VALUES (NEW.id, v_age, v_aff,
              COALESCE(NULLIF(btrim(m->>'region'), ''), '미상'),
              COALESCE(NULLIF(btrim(m->>'phone'), ''), '운영진이 따로 확인'),
              '가입할 때 끗짱을 골랐어요',
              -- 가입 둘째 화면에서 적은 것 (없으면 옛 문구)
              COALESCE(NULLIF(left(btrim(COALESCE(m->>'k_motive', '')), 300), ''), '가입 시 자동으로 올라온 신청이에요'),
              NULLIF(left(btrim(COALESCE(m->>'k_experience', '')), 300), ''),
              -- 가입 둘째 화면에서 청소년 보호 수칙에 동의했으면 그때를 서버 시계로 남긴다
              CASE WHEN m->>'k_pledge' = 'true' THEN now() END,
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
-- 기대: 1
SELECT count(*) AS 가입함수_1이어야 FROM pg_proc WHERE proname = 'handle_new_user' AND prosrc LIKE '%k_pledge%';
