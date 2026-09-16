-- 한끗독서 마이그레이션 21
-- 끗짱 승인제 — 관리자가 승인해야 루틴을 만들 수 있다
--
-- 【배경】 지금은 가입 화면에서 '끗짱'을 고르기만 하면 즉시 루틴을 만들고
--   청소년들과 한 그룹에 들어간다. 심사가 없다. 돈 문제가 아니라 아동 안전
--   문제라서 실서비스 전에 반드시 막아야 한다.
--
-- 【같이 막는 구멍】 profiles_self_update 정책이 role 컬럼을 막지 않아서,
--   청소년으로 가입한 뒤 자기 프로필의 role 을 'kkutjjang' 으로 PATCH 하면
--   그냥 끗짱이 됐다. 승인제를 얹어도 이 구멍이 있으면 의미가 없으므로
--   프로필 트리거로 role 을 못 바꾸게 한다.
--   → 이제 role 은 오직 decide_kkut_application() 으로만 바뀐다.
--
-- 【신청서를 profiles 에 넣지 않은 이유】
--   profiles_read 가 TO authenticated USING (true) 라서, 나이·연락처·지원동기를
--   profiles 에 넣으면 청소년 계정이 전부 읽을 수 있다. 별도 테이블로 뺀다.

-- ────────────────────────────────────────────────────────────────────
-- 1. 신청서
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS kkut_applications (
  user_id       uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  age           int  NOT NULL CHECK (age BETWEEN 14 AND 100),
  affiliation   text NOT NULL,                 -- 소속 (직장·학교·단체, 없으면 '없음')
  region        text NOT NULL,                 -- 활동 지역
  contact       text NOT NULL,                 -- 연락처 (관리자가 확인 연락)
  intro         text NOT NULL,                 -- 어떤 분인지
  motive        text NOT NULL,                 -- 어떤 마음으로 함께하는지
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','approved','rejected')),
  reject_reason text,
  applied_at    timestamptz NOT NULL DEFAULT now(),
  decided_at    timestamptz,
  decided_by    uuid REFERENCES auth.users ON DELETE SET NULL
);

COMMENT ON TABLE kkut_applications IS
  '끗짱 신청서. 청소년을 만나는 자리라 관리자가 사람을 보고 승인한다. 본인과 관리자만 읽는다';

CREATE INDEX IF NOT EXISTS kkut_applications_status_idx
  ON kkut_applications (status, applied_at DESC);

-- ────────────────────────────────────────────────────────────────────
-- 2. RLS — 본인과 관리자만
-- ────────────────────────────────────────────────────────────────────
ALTER TABLE kkut_applications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS kkut_app_read ON kkut_applications;
CREATE POLICY kkut_app_read ON kkut_applications FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin());

DROP POLICY IF EXISTS kkut_app_self_insert ON kkut_applications;
CREATE POLICY kkut_app_self_insert ON kkut_applications FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() OR is_admin());

DROP POLICY IF EXISTS kkut_app_self_update ON kkut_applications;
CREATE POLICY kkut_app_self_update ON kkut_applications FOR UPDATE TO authenticated
  USING      (user_id = auth.uid() OR is_admin())
  WITH CHECK (user_id = auth.uid() OR is_admin());

-- ⚠️ 위 UPDATE 정책만으로는 신청자가 자기 status 를 'approved' 로 바꿀 수 있다.
--    profiles 에서 밟았던 것과 같은 지뢰다. 트리거로 막는다.
CREATE OR REPLACE FUNCTION check_kkut_application() RETURNS trigger AS $$
BEGIN
  -- auth.uid() 가 NULL = SQL 편집기·서버 쪽에서 직접 넣는 경우.
  -- 익명은 정책이 TO authenticated 라 애초에 여기까지 오지 못한다
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;

  NEW.user_id := auth.uid();

  IF TG_OP = 'UPDATE' THEN
    -- 심사 중이거나 이미 승인된 신청서는 본인이 못 고친다.
    -- (승인 뒤에 내용을 바꿔치기하면 승인의 근거가 사라진다)
    IF OLD.status <> 'rejected' THEN
      RAISE EXCEPTION '심사 중이거나 이미 처리된 신청서는 수정할 수 없습니다';
    END IF;
  END IF;

  -- 신청·재신청은 무조건 심사 대기부터
  NEW.status        := 'pending';
  NEW.applied_at    := now();
  NEW.reject_reason := NULL;
  NEW.decided_at    := NULL;
  NEW.decided_by    := NULL;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS kkut_applications_check ON kkut_applications;
CREATE TRIGGER kkut_applications_check BEFORE INSERT OR UPDATE ON kkut_applications
  FOR EACH ROW EXECUTE FUNCTION check_kkut_application();

-- 신청서는 아무도 지우지 않는다 (승인 이력이 남아야 한다). DELETE 정책 없음 = 전부 거부

-- ────────────────────────────────────────────────────────────────────
-- 3. 승인 여부 판정
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION is_approved_kkut(p_user uuid DEFAULT auth.uid())
RETURNS boolean AS $$
  SELECT COALESCE(
    (SELECT status = 'approved' FROM kkut_applications WHERE user_id = p_user),
    false);
$$ LANGUAGE sql SECURITY DEFINER STABLE;

COMMENT ON FUNCTION is_approved_kkut(uuid) IS
  'COALESCE 필수. 신청서가 없으면 SELECT 가 NULL 을 돌려주고, IF NOT NULL 은 통과해 버린다 (migration-06 과 같은 지뢰)';

REVOKE EXECUTE ON FUNCTION is_approved_kkut(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION is_approved_kkut(uuid) TO authenticated;

-- ────────────────────────────────────────────────────────────────────
-- 4. 프로필 — 스스로 끗짱이 될 수 없게
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_profile_write() RETURNS trigger AS $$
BEGIN
  -- 익명은 profiles 를 수정할 수 없다 (정책이 id = auth.uid() 를 요구하는데
  -- NULL 은 어떤 행과도 안 맞는다). 그래서 NULL 은 SQL 편집기·서버 쪽이다
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;

  IF TG_OP = 'UPDATE' THEN
    NEW.id         := OLD.id;
    NEW.role       := OLD.role;        -- 역할은 승인 함수로만 바뀐다
    NEW.created_at := OLD.created_at;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS profiles_check ON profiles;
CREATE TRIGGER profiles_check BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION check_profile_write();

-- ────────────────────────────────────────────────────────────────────
-- 5. 루틴 생성 — 승인된 끗짱만
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
DECLARE
  v_role   text;
  v_amount int;
BEGIN
  -- 적립액은 누가 만들든 설정값으로 붙인다. 관리자도 예외 없음
  IF TG_OP = 'INSERT' THEN
    SELECT amount_per_cert INTO v_amount FROM dokseo_settings WHERE id = 1;
    NEW.amount_per_cert := COALESCE(v_amount, 1300);
  ELSE
    NEW.amount_per_cert := OLD.amount_per_cert;
  END IF;

  IF is_admin() THEN RETURN NEW; END IF;

  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role IS DISTINCT FROM 'kkutjjang' THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  IF NOT is_approved_kkut() THEN
    RAISE EXCEPTION '끗짱 승인을 받아야 루틴을 만들 수 있습니다';
  END IF;

  NEW.led_by := auth.uid();
  IF TG_OP = 'INSERT' THEN NEW.status := 'recruit'; END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_check ON routines;
CREATE TRIGGER routines_check BEFORE INSERT OR UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION check_routine_write();

-- 정책에도 한 겹 더 (트리거 하나에만 기대지 않는다)
DROP POLICY IF EXISTS routines_kkutjjang_insert ON routines;
CREATE POLICY routines_kkutjjang_insert ON routines FOR INSERT
  WITH CHECK (
    led_by = auth.uid()
    AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'kkutjjang')
    AND is_approved_kkut()
  );

-- ────────────────────────────────────────────────────────────────────
-- 6. 관리자 — 목록 조회와 승인/반려
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION kkut_applications_admin()
RETURNS TABLE (
  user_id uuid, name text, email text,
  age int, affiliation text, region text, contact text,
  intro text, motive text,
  status text, reject_reason text,
  applied_at timestamptz, decided_at timestamptz,
  routine_count bigint
) AS $$
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  RETURN QUERY
    SELECT a.user_id, p.name, u.email::text,
           a.age, a.affiliation, a.region, a.contact,
           a.intro, a.motive,
           a.status, a.reject_reason,
           a.applied_at, a.decided_at,
           (SELECT count(*) FROM routines r WHERE r.led_by = a.user_id)
      FROM kkut_applications a
      JOIN profiles   p ON p.id = a.user_id
      JOIN auth.users u ON u.id = a.user_id
     ORDER BY (a.status = 'pending') DESC, a.applied_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION kkut_applications_admin() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION kkut_applications_admin() TO authenticated;


CREATE OR REPLACE FUNCTION decide_kkut_application(
  p_user    uuid,
  p_approve boolean,
  p_reason  text DEFAULT NULL
) RETURNS void AS $$
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  IF NOT p_approve AND COALESCE(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION '반려 사유를 적어주세요';
  END IF;

  UPDATE kkut_applications
     SET status        = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         reject_reason = CASE WHEN p_approve THEN NULL ELSE p_reason END,
         decided_at    = now(),
         decided_by    = auth.uid()
   WHERE user_id = p_user;

  IF NOT FOUND THEN
    RAISE EXCEPTION '신청서를 찾을 수 없습니다';
  END IF;

  IF p_approve THEN
    -- 역할은 여기서만 바뀐다 (profiles 트리거가 본인 수정을 막고 있다)
    UPDATE profiles SET role = 'kkutjjang' WHERE id = p_user;
  ELSE
    -- 승인을 거둬들이면 이미 만든 루틴은 모집을 닫는다.
    -- 이미 참여 중인 청소년의 기록은 건드리지 않는다 — 아이 잘못이 아니다
    UPDATE routines SET status = 'closed'
     WHERE led_by = p_user AND status = 'recruit';
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION decide_kkut_application(uuid, boolean, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION decide_kkut_application(uuid, boolean, text) TO authenticated;

-- ────────────────────────────────────────────────────────────────────
-- 7. 이미 활동 중인 끗짱은 승인된 것으로 넘긴다
--    (안 그러면 지금 돌아가는 루틴의 끗짱이 수정도 못 하게 된다)
-- ────────────────────────────────────────────────────────────────────
INSERT INTO kkut_applications (user_id, age, affiliation, region, contact, intro, motive, status, decided_at)
SELECT p.id, 30, '(승인제 도입 전 등록)', COALESCE(p.region, '-'), '-',
       '승인제를 만들기 전부터 활동하던 끗짱입니다.',
       '승인제 도입 시점에 자동 승인 처리되었습니다.',
       'approved', now()
  FROM profiles p
 WHERE p.role = 'kkutjjang'
ON CONFLICT (user_id) DO NOTHING;
