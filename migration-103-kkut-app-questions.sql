-- 한끗독서 마이그레이션 103
-- 끗짱 신청서를 보강한다 — 판단할 재료가 소개 한 줄과 동기 한 줄뿐이었다
--
-- 【새 칸】
--   experience  청소년과 함께한 경험 (학교·독서모임·봉사 등. 없으면 「없음」이라고 적는다. **필수**)
--   referrer    추천해 준 분이나, 활동을 볼 수 있는 곳(블로그·단체 주소 등) (선택)
--   pledge_at   「여러 청소년과 함께하는 역할을 이해했다 + 개인 연락·사진 요구를 하지 않는다」에 동의한 때. **필수**
-- 【서버가 지킨다】 경험을 비워 두거나 약속에 동의하지 않으면 보내지지 않는다. 동의한 때는 서버 시계로 찍는다 —
--   앱이 보낸 시각을 믿지 않는다.
-- 【옛 신청서】 이미 낸 신청서(승인·반려 포함)는 이 칸이 비어 있다. 건드리지 않는다.
--
-- ⚠️ 21·22·33 뒤에 돌린다.

ALTER TABLE kkut_applications
  ADD COLUMN IF NOT EXISTS experience text,
  ADD COLUMN IF NOT EXISTS referrer   text,
  ADD COLUMN IF NOT EXISTS pledge_at  timestamptz;

-- ── 신청할 때 지킬 것 ──────────────────────────────────
CREATE OR REPLACE FUNCTION check_kkut_application() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  NEW.user_id := auth.uid();

  IF TG_OP = 'UPDATE' AND OLD.status <> 'rejected' THEN
    RAISE EXCEPTION '심사 중이거나 이미 처리된 신청서는 수정할 수 없습니다';
  END IF;

  NEW.status := 'pending';
  NEW.decided_at := NULL; NEW.decided_by := NULL; NEW.reject_reason := NULL;

  IF COALESCE(NEW.age, 0) < 14 THEN
    RAISE EXCEPTION '끗짱은 14세부터 신청할 수 있어요';
  END IF;
  IF COALESCE(btrim(NEW.intro), '') = '' OR COALESCE(btrim(NEW.motive), '') = '' THEN
    RAISE EXCEPTION '어떤 분인지와 지원 동기를 적어주세요';
  END IF;
  IF COALESCE(btrim(NEW.experience), '') = '' THEN
    RAISE EXCEPTION '청소년과 함께한 경험을 적어주세요. 없으면 「없음」이라고 적어도 괜찮아요';
  END IF;
  IF NEW.pledge_at IS NULL THEN
    RAISE EXCEPTION '청소년 보호 약속에 동의해 주세요';
  END IF;
  NEW.pledge_at := now();      -- 동의한 때는 서버 시계로

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 운영진이 보는 목록에 새 칸을 더한다 ────────────────
-- 돌려주는 칸이 늘어서 지우고 다시 만든다
DROP FUNCTION IF EXISTS kkut_applications_admin();
CREATE OR REPLACE FUNCTION kkut_applications_admin()
RETURNS TABLE (
  user_id uuid, name text, email text,
  age int, affiliation text, region text, contact text,
  intro text, motive text,
  status text, reject_reason text,
  applied_at timestamptz, decided_at timestamptz,
  routine_count bigint,
  experience text, referrer text, pledge_at timestamptz
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
           (SELECT count(*) FROM routines r WHERE r.led_by = a.user_id),
           a.experience, a.referrer, a.pledge_at
      FROM kkut_applications a
      JOIN profiles   p ON p.id = a.user_id
      JOIN auth.users u ON u.id = a.user_id
     ORDER BY (a.status = 'pending') DESC, a.applied_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION kkut_applications_admin() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION kkut_applications_admin() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 목록 함수는 관리자로 로그인해야 부를 수 있어서(편집기에선 거부된다) 몸통이 바뀐 것만 본다
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'kkut_applications'
           AND column_name IN ('experience', 'referrer', 'pledge_at'))                 AS 칸_3이어야,
       (pg_get_functiondef('check_kkut_application'::regproc) LIKE '%pledge_at%')      AS 약속_검사,
       (pg_get_function_result('kkut_applications_admin'::regproc) LIKE '%pledge_at%') AS 운영진목록_새칸;
