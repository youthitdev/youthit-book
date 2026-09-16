-- 한끗독서 마이그레이션 21 · 22 · 23 한 번에
-- 끗짱 승인제 + 자격 조건(30일) + 기록 열람 좁히기
-- 2026-09-16. 위에서 아래로 한 번에 실행하면 된다


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
    -- 승인을 거둬들이면 아직 모집 중인 루틴은 닫는다.
    -- status CHECK 가 ('recruit','active','done') 뿐이라 'done' 을 쓴다.
    -- 이미 진행 중(active)인 루틴과 청소년의 기록은 건드리지 않는다 — 아이 잘못이 아니다
    UPDATE routines SET status = 'done'
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


-- 한끗독서 마이그레이션 23
-- 기록 열람을 같은 루틴 안으로 좁힌다
--
-- 【문제】 지금 정책이 이렇다.
--     certs_read ON certifications FOR SELECT TO authenticated USING (true)
--   로그인한 계정이면 누구나 전체 인증 기록을 읽는다. 사진 주소·필사 문장·
--   읽은 쪽수·이름이 전부 나간다. parts_read, comments_read, profiles_read 도 같다.
--   가입은 아무나 할 수 있으므로 사실상 열려 있는 셈이었다.
--
-- 【바꾸는 것】 볼 수 있는 사람은 셋뿐이다.
--     ① 본인  ② 같은 루틴 참여자  ③ 그 루틴을 이끄는 끗짱  (+ 운영진)
--
-- 【집계는 그대로 보인다】 홈 지표·후원자 화면·랜딩 서가는 전부
--   SECURITY DEFINER 함수(dokseo_reading_stats, dokseo_public_quotes 등)로
--   익명 집계만 내보내므로 이 변경에 영향받지 않는다.
--   참여 인원 수도 routine_people_count() 로 계속 나간다.
--
-- ⚠️ 사진 파일 자체는 cert-photos 공개 버킷에 있다. 주소를 아는 사람은
--   여전히 열 수 있다 (주소는 추측할 수 없는 난수). 이 마이그레이션은
--   '주소가 새로 흘러나가는 것'을 막는다. 버킷을 비공개로 돌리는 건
--   서명 URL 작업이 따로 필요해 여기서 하지 않는다.

-- ────────────────────────────────────────────────────────────────────
-- 1. 내가 볼 수 있는 범위
--    SECURITY DEFINER 라 RLS 를 타지 않는다 → 정책 안에서 재귀가 생기지 않는다
--    집합을 한 번에 돌려주므로 행마다 함수를 부르지 않는다
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION visible_routine_ids()
RETURNS SETOF bigint AS $$
  SELECT r.id FROM routines r WHERE r.led_by = auth.uid()
  UNION
  SELECT p.routine_id FROM routine_participants p
   WHERE p.user_id = auth.uid() AND p.status = 'approved';
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION visible_routine_ids() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION visible_routine_ids() TO authenticated;


CREATE OR REPLACE FUNCTION visible_user_ids()
RETURNS SETOF uuid AS $$
  SELECT q.user_id
    FROM routine_participants q
   WHERE q.status = 'approved'
     AND q.routine_id IN (SELECT visible_routine_ids())
  UNION
  SELECT r.led_by FROM routines r
   WHERE r.led_by IS NOT NULL AND r.id IN (SELECT visible_routine_ids());
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION visible_user_ids() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION visible_user_ids() TO authenticated;


CREATE OR REPLACE FUNCTION can_see_cert(p_cert bigint)
RETURNS boolean AS $$
  SELECT COALESCE((
    SELECT c.user_id = auth.uid()
        OR c.routine_id IN (SELECT visible_routine_ids())
      FROM certifications c WHERE c.id = p_cert), false);
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION can_see_cert(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION can_see_cert(bigint) TO authenticated;

-- ────────────────────────────────────────────────────────────────────
-- 2. 정책 교체
-- ────────────────────────────────────────────────────────────────────

-- 인증 기록
DROP POLICY IF EXISTS certs_read ON certifications;
CREATE POLICY certs_read ON certifications FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR is_admin()
    OR routine_id IN (SELECT visible_routine_ids())
  );

-- 참여자 (참여 각오·읽을 책 사진이 들어 있다)
DROP POLICY IF EXISTS parts_read ON routine_participants;
CREATE POLICY parts_read ON routine_participants FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR is_admin()
    OR routine_id IN (SELECT visible_routine_ids())
  );

-- 댓글
DROP POLICY IF EXISTS comments_read ON cert_comments;
CREATE POLICY comments_read ON cert_comments FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR is_admin()
    OR can_see_cert(cert_id)
  );

-- 프로필 (이름). 같은 루틴에 없는 사람의 이름은 알 필요가 없다
DROP POLICY IF EXISTS profiles_read ON profiles;
CREATE POLICY profiles_read ON profiles FOR SELECT TO authenticated
  USING (
    id = auth.uid()
    OR is_admin()
    OR id IN (SELECT visible_user_ids())
  );

-- ⚠️ 댓글을 남길 때도 볼 수 있는 인증에만 달 수 있어야 한다.
--    (INSERT 정책이 user_id 만 봤기 때문에, 남의 루틴 인증 id 를 찍어 넣으면 달렸다)
DROP POLICY IF EXISTS comments_own ON cert_comments;
CREATE POLICY comments_own ON cert_comments FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND can_see_cert(cert_id));

-- ────────────────────────────────────────────────────────────────────
-- 3. 인덱스 — 정책이 매 조회마다 타는 길
-- ────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS parts_user_status_idx
  ON routine_participants (user_id, status);
CREATE INDEX IF NOT EXISTS parts_routine_status_idx
  ON routine_participants (routine_id, status);
CREATE INDEX IF NOT EXISTS routines_led_by_idx
  ON routines (led_by);
CREATE INDEX IF NOT EXISTS certs_routine_idx
  ON certifications (routine_id);
