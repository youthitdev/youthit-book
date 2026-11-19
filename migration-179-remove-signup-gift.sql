-- 한끗독서 마이그레이션 179
-- 가입 선물(웰컴 이벤트) 자동 지급 끄기 (2026-11-19 사용자: 「웰컴 이벤트 일괄 삭제, 자동 포인트 적립이면 그 기능도 삭제. 내년 1월 중 가입 이벤트 진행 예정」)
--
-- 【하는 일】 167 에서 가입 함수(handle_new_user)에 더했던 「가입 선물 50N」 단계를 뺀다.
--   · 이제 새로 가입해도 나다움을 자동으로 주지 않는다. 나머지(프로필 만들기·끗짱 신청 자동 접수 등)는 167·160 과 같다.
--   · **이미 받은 사람의 50N 은 그대로 둔다** (회수하지 않는다). 회수하려면 관리자 「나다움 지급」 내역에서 줄마다 「회수」한다.
-- 내년 1월 이벤트: 기간과 금액이 정해지면 167 과 같은 방식으로 새 마이그레이션을 만든다 (167 파일은 참고용으로 남겨 둔다 — 다시 돌리지 말 것).
-- 되돌리려면: 167 을 다시 돌린다 (기간이 지났으면 지급되지 않는다).
-- ⚠️ 167 뒤에 돌린다. 여러 번 돌려도 된다.

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
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 여기서 막으면 가입 자체가 통째로 막힌다 (한끗루틴에서 겪었다)
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 가입 함수에 선물 단계 0 / 지금까지 가입 선물을 받은 사람 수(그대로 남음)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'handle_new_user' AND prosrc LIKE '%가입 선물%') AS 선물단계_0이어야,
       (SELECT count(*) FROM nadaum_grants WHERE reason LIKE '가입 선물%' AND voided_at IS NULL)        AS 이미_받은_사람_그대로;
