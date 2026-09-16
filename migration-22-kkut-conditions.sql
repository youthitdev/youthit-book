-- 한끗독서 마이그레이션 22
-- 끗짱 자격 조건 — 14세 이상, 루틴을 30일 이상 해 본 사람
--
-- 【배경】 끗짱은 가입할 때 고르는 역할이 아니라, 청소년으로 30일을 읽고 나면
--   열리는 다음 단계다. 15·30·66일 사다리가 여기로 이어진다.
--   나이 하한 14세는 migration-21 의 CHECK 로 이미 걸려 있다.
--
-- 【30일을 어떻게 세나】 인증한 '날'의 수(DISTINCT cert_date)로 센다.
--   루틴을 두 개 하면서 같은 날 두 번 인증해도 하루다.
--   연속이 아니라 누적이다 — 하루 빠진 게 전부를 잃는 일이 되면 안 된다.
--
-- 【섭외한 어른 끗짱】 유스보이스가 데려온 끗짱은 30일이 있을 리 없다.
--   관리자가 초대하면 30일 조건만 면제된다. 신청서는 본인이 쓰고 승인도 그대로 받는다.

-- ────────────────────────────────────────────────────────────────────
-- 1. 조건값은 설정으로 (코드를 안 고치고 바꾼다)
-- ────────────────────────────────────────────────────────────────────
ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS kkut_min_cert_days int NOT NULL DEFAULT 30;

COMMENT ON COLUMN dokseo_settings.kkut_min_cert_days IS
  '끗짱을 신청하려면 인증한 날이 며칠 이상이어야 하는가. 0 이면 조건 없음';

-- 관리자가 초대한 사람은 위 조건을 건너뛴다
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS kkut_invited boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN profiles.kkut_invited IS
  '운영진이 섭외한 끗짱. 30일 조건만 면제된다. 승인은 그대로 받는다';

-- ⚠️ migration-21 의 check_profile_write 가 role 만 고정하고 있다.
--    kkut_invited 도 본인이 못 켜게 막는다 (켜면 조건을 건너뛴다)
CREATE OR REPLACE FUNCTION check_profile_write() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;

  IF TG_OP = 'UPDATE' THEN
    NEW.id           := OLD.id;
    NEW.role         := OLD.role;          -- 역할은 승인 함수로만 바뀐다
    NEW.kkut_invited := OLD.kkut_invited;  -- 초대는 관리자만 켠다
    NEW.created_at   := OLD.created_at;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ────────────────────────────────────────────────────────────────────
-- 2. 내가 읽은 날 수
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION cert_days(p_user uuid DEFAULT auth.uid())
RETURNS int AS $$
  SELECT COALESCE(count(DISTINCT cert_date), 0)::int
    FROM certifications WHERE user_id = p_user;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION cert_days(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION cert_days(uuid) TO authenticated;


-- 신청 화면이 쓰는 것. 몇 일 채웠고 몇 일이 필요한지 한 번에 돌려준다
CREATE OR REPLACE FUNCTION kkut_eligibility()
RETURNS TABLE (days int, need int, invited boolean, eligible boolean) AS $$
  SELECT d.days, n.need, p.invited,
         COALESCE(p.invited OR d.days >= n.need, false)
    FROM (SELECT cert_days() AS days) d,
         (SELECT COALESCE((SELECT kkut_min_cert_days FROM dokseo_settings WHERE id = 1), 30) AS need) n,
         (SELECT COALESCE((SELECT kkut_invited FROM profiles WHERE id = auth.uid()), false) AS invited) p;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION kkut_eligibility() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION kkut_eligibility() TO authenticated;

-- ────────────────────────────────────────────────────────────────────
-- 3. 신청서 트리거에 조건 추가
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_kkut_application() RETURNS trigger AS $$
DECLARE
  v_need    int;
  v_days    int;
  v_invited boolean;
BEGIN
  -- auth.uid() 가 NULL = SQL 편집기·서버 쪽에서 직접 넣는 경우
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;

  NEW.user_id := auth.uid();

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status <> 'rejected' THEN
      RAISE EXCEPTION '심사 중이거나 이미 처리된 신청서는 수정할 수 없습니다';
    END IF;
  END IF;

  SELECT COALESCE(kkut_min_cert_days, 30) INTO v_need FROM dokseo_settings WHERE id = 1;
  v_need := COALESCE(v_need, 30);
  SELECT COALESCE(kkut_invited, false) INTO v_invited FROM profiles WHERE id = auth.uid();
  v_days := cert_days();

  IF NOT COALESCE(v_invited, false) AND v_days < v_need THEN
    RAISE EXCEPTION '루틴을 %일 이상 해야 끗짱을 신청할 수 있어요 (지금 %일)', v_need, v_days;
  END IF;

  NEW.status        := 'pending';
  NEW.applied_at    := now();
  NEW.reject_reason := NULL;
  NEW.decided_at    := NULL;
  NEW.decided_by    := NULL;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ────────────────────────────────────────────────────────────────────
-- 4. 관리자 — 섭외한 끗짱 초대
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION invite_kkut(p_email text, p_on boolean DEFAULT true)
RETURNS text AS $$
DECLARE v_id uuid; v_name text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT id INTO v_id FROM auth.users WHERE lower(email) = lower(btrim(p_email));
  IF v_id IS NULL THEN
    RAISE EXCEPTION '그 이메일로 가입한 계정이 없습니다. 먼저 앱에 가입해 달라고 안내해 주세요';
  END IF;

  UPDATE profiles SET kkut_invited = p_on WHERE id = v_id RETURNING name INTO v_name;
  IF v_name IS NULL THEN RAISE EXCEPTION '프로필이 없습니다'; END IF;

  RETURN v_name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION invite_kkut(text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION invite_kkut(text, boolean) TO authenticated;
