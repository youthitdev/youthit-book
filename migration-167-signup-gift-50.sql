-- 한끗독서 마이그레이션 167
-- 청소년으로 가입하면 나다움 50N 자동 지급 — 12월 17일까지 가입한 사람 (2026-11-13 사용자)
--
-- 【하는 일】 가입할 때 돌아가는 handle_new_user 에 한 단계를 더한다.
--   · 청소년으로 가입한 사람(끗짱을 고르지 않았고 만 19세 이하)에게 nadaum_grants 로 50N 을 넣는다.
--   · 한국 시간으로 2026-12-17 이 끝날 때까지 가입한 사람만 받는다. 18일부터는 저절로 안 준다 (이 파일을 또 돌릴 필요 없다).
--   · 이미 가입한 사람에게는 주지 않는다. 앞으로 가입하는 사람만.
--   · 받은 나다움은 MY 의 나다움 내역에 「가입 선물」로 보이고, 교환권 계산에 같이 들어간다.
--   · 지급이 실패해도 가입은 그대로 된다 (가입이 막히면 안 된다).
-- 나머지는 160 의 handle_new_user 와 같다.
--
-- ⚠️ 160 뒤에 돌린다. 여러 번 돌려도 된다 (이미 준 사람에게 또 주지는 않는다).

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
              COALESCE(NULLIF(left(btrim(COALESCE(m->>'k_motive', '')), 300), ''), '가입 시 자동으로 올라온 신청이에요'),
              NULLIF(left(btrim(COALESCE(m->>'k_experience', '')), 300), ''),
              CASE WHEN m->>'k_pledge' = 'true' THEN now() END,
              'pending', now())
      ON CONFLICT (user_id) DO NOTHING;

    -- 가입 선물: 청소년으로 가입했고(끗짱 아님·만 19세 이하) 12월 17일(한국 시간)까지면 50N
    ELSIF v_age IS NOT NULL AND v_age BETWEEN 14 AND 19
          AND COALESCE(m->>'join_role', 'youth') <> 'kkut'
          AND (now() AT TIME ZONE 'Asia/Seoul') < timestamp '2026-12-18 00:00:00'
          AND NOT EXISTS (SELECT 1 FROM nadaum_grants g WHERE g.user_id = NEW.id AND g.reason LIKE '가입 선물%') THEN
      INSERT INTO nadaum_grants (user_id, amount, reason, granted_by)
      VALUES (NEW.id, 50, '가입 선물 (12월 17일까지 가입한 청소년)', NULL);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 여기서 막으면 가입 자체가 통째로 막힌다 (한끗루틴에서 겪었다)
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 가입 함수에 선물 단계 1 / 지금까지 가입 선물을 받은 사람 0 (돌린 직후)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'handle_new_user' AND prosrc LIKE '%가입 선물%') AS 선물단계_1이어야,
       (SELECT count(*) FROM nadaum_grants WHERE reason LIKE '가입 선물%')                              AS 받은_사람_지금_0;
