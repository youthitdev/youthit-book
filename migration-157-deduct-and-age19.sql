-- 한끗독서 마이그레이션 157
-- 1) 나다움 차감 (2026-11-11 요청) · 2) 청소년 나이 상한을 만 19세로 (2026-11-11 요청)
--
-- 【1. 나다움 차감】 QR 오류로 교환권이 안 쓰인 것으로 남았지만 실제로는 책을 교환한 경우처럼,
--   이미 받은 나다움을 줄여야 할 때 쓴다. 손으로 준 나다움의 「회수」와 달리 어떤 나다움이든 뺄 수 있다.
--   · 관리자 화면 「나다움 지급」 탭에서 청소년을 골라 150N 단위가 아니어도 1~1000N 을 뺀다. 사유는 꼭 적고, 받은 아이에게 알림이 간다.
--   · 지급과 같은 표(nadaum_grants)에 마이너스 숫자로 남는다. 그래서 합계·교환권 계산(dokseo_points)은 손대지 않는다.
--   · 지금 가진 나다움보다 많이는 못 뺀다. 잘못 뺐으면 지급 내역에서 「차감 취소」(= 기존 회수)로 되돌린다.
--
-- 【2. 만 19세】 청소년은 만 14~19세다. 가입 때 만 19세를 넘으면 끗짱 신청 대기로 올라가는 기준을 20 → 19 로 바꾼다
--   (132 의 handle_new_user 를 기준 한 곳만 바꿔 다시 만든다). 이미 가입한 20세 회원은 그대로 쓴다.
--
-- ⚠️ 132·153 뒤에 돌린다. 여러 번 돌려도 된다.

-- ── 1. 차감 ────────────────────────────────────────────
ALTER TABLE nadaum_grants DROP CONSTRAINT IF EXISTS nadaum_grants_amount_check;
ALTER TABLE nadaum_grants ADD CONSTRAINT nadaum_grants_amount_check CHECK (amount BETWEEN -1000 AND 1000 AND amount <> 0);

CREATE OR REPLACE FUNCTION deduct_nadaum(p_user uuid, p_amount int, p_reason text) RETURNS jsonb AS $$
DECLARE v_role text; v_lead boolean; v_gone timestamptz; v_id bigint; v_why text; v_have int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  v_why := btrim(COALESCE(p_reason, ''));
  IF v_why = '' THEN RAISE EXCEPTION '사유를 적어주세요'; END IF;
  IF p_amount IS NULL OR p_amount < 1 OR p_amount > 1000 THEN
    RAISE EXCEPTION '한 번에 1~1000N 까지 뺄 수 있어요. 더 뺄 일이 있으면 나눠서 빼주세요';
  END IF;

  SELECT COALESCE(role, 'youth'), COALESCE(can_lead, false), withdrawn_at
    INTO v_role, v_lead, v_gone FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 회원이 없어요'; END IF;
  IF v_gone IS NOT NULL THEN RAISE EXCEPTION '탈퇴한 회원이에요'; END IF;
  IF v_role <> 'youth' OR v_lead THEN RAISE EXCEPTION '청소년만 뺄 수 있어요'; END IF;

  v_have := COALESCE((dokseo_points(p_user)->>'points')::int, 0);
  IF p_amount > v_have THEN
    RAISE EXCEPTION '지금 가진 나다움(%N)보다 많이 뺄 수 없어요', v_have;
  END IF;

  INSERT INTO nadaum_grants (user_id, amount, reason, granted_by)
  VALUES (p_user, -p_amount, v_why, auth.uid()) RETURNING id INTO v_id;

  BEGIN
    PERFORM notify_push(p_user, '나다움 ' || p_amount || 'N이 정리됐어요', left(v_why, 60),
                        '/youthit-book/app.html?tab=my');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'amount', -p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION deduct_nadaum(uuid, int, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION deduct_nadaum(uuid, int, text) TO authenticated;

-- ── 2. 만 19세 ─────────────────────────────────────────
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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 차감 함수 1 · 가입 함수에 19 기준이 들어 있다 1 · 마이너스를 받는 제약 1
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'deduct_nadaum')                                             AS 차감함수_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'handle_new_user' AND prosrc LIKE '%v_age > 19%')           AS 가입함수_19_1이어야,
       (SELECT count(*) FROM pg_constraint WHERE conname = 'nadaum_grants_amount_check'
           AND pg_get_constraintdef(oid) LIKE '%-1000%')                                                          AS 제약_1이어야;
