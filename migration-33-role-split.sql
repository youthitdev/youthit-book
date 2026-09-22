-- 한끗독서 마이그레이션 33
-- 역할을 두 축으로 나눈다
--
--   role     youth | adult    돈을 받을 사람인가 (포인트·교환권·책)
--   can_lead true | false     루틴을 만들 수 있는가 (끗짱)
--
-- 왜:
--   끗짱 자격이 「루틴 30일 이상 한 사람」이었다. 그러면 끗짱은 원래
--   청소년에서 나온다. 그런데 승인하는 순간 role 이 'kkutjjang' 이 되면서
--   myRoutines() 가 '내가 만든 루틴'으로 뒤집혀, 30일을 읽은 아이의 참여
--   기록과 포인트가 화면에서 통째로 사라졌다. 가장 열심히 읽은 아이에게
--   벌을 주는 구조였다.
--
--   그렇다고 합칠 수도 없다. 끗짱 중에는 섭외해 온 어른이 있고, 도서기금은
--   청소년에게 쓰는 돈이다. 기부금 사용명세에도 그렇게 적힌다.
--
--   30일 기준은 없앤다. 30일 읽은 것과 아이들을 맡길 만한 사람인 것은
--   상관이 없다. 소속·나이·지원동기를 받고 사람이 판단한다. 14세 미만만
--   자동으로 막는다 — 이건 실력 판단이 아니라 아동 보호선이다.

-- ── 1. 컬럼 먼저 ───────────────────────────────────────
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS can_lead boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN profiles.can_lead IS '루틴을 만들 수 있는가 (끗짱). 승인 함수로만 바뀐다';
COMMENT ON COLUMN profiles.role IS 'youth 포인트·교환권·책을 받는 청소년 · adult 그 대상이 아닌 어른';

-- ── 2. 기존 끗짱을 옮긴다 ──────────────────────────────
-- 지금 끗짱은 섭외해 온 분이라 adult 로 본다. 청소년 끗짱이 생기면
-- 승인 창에서 youth 로 두면 된다
UPDATE profiles SET can_lead = true WHERE role = 'kkutjjang';
UPDATE profiles SET role = 'adult'  WHERE role = 'kkutjjang';

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_role_check CHECK (role IN ('youth', 'adult'));
ALTER TABLE profiles ALTER COLUMN role SET DEFAULT 'youth';

-- ── 3. 스스로 못 바꾸게 ────────────────────────────────
CREATE OR REPLACE FUNCTION check_profile_write() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.id         := OLD.id;
    NEW.role       := OLD.role;        -- 둘 다 승인 함수로만 바뀐다
    NEW.can_lead   := OLD.can_lead;
    NEW.created_at := OLD.created_at;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. 끗짱 판정은 can_lead 로 ─────────────────────────
-- 신청서 상태가 아니라 프로필을 본다. 초대로 바로 켜 줄 수도 있어야 한다
CREATE OR REPLACE FUNCTION is_approved_kkut(p_user uuid DEFAULT auth.uid())
RETURNS boolean AS $$
  SELECT COALESCE((SELECT can_lead FROM profiles WHERE id = p_user), false);
$$ LANGUAGE sql SECURITY DEFINER STABLE;
COMMENT ON FUNCTION is_approved_kkut(uuid) IS
  'COALESCE 필수. 프로필이 없으면 NULL 이 돌아오고 IF NOT NULL 은 통과해 버린다';
REVOKE EXECUTE ON FUNCTION is_approved_kkut(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION is_approved_kkut(uuid) TO authenticated;

-- ── 5. 승인은 can_lead 를 켜고, 어른인지만 따로 정한다 ──
CREATE OR REPLACE FUNCTION decide_kkut_application(
  p_user uuid, p_approve boolean, p_reason text DEFAULT NULL, p_adult boolean DEFAULT NULL
) RETURNS void AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;
  IF NOT p_approve AND COALESCE(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION '반려 사유를 적어주세요';
  END IF;

  UPDATE kkut_applications
     SET status        = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         reject_reason = CASE WHEN p_approve THEN NULL ELSE p_reason END,
         decided_at    = now(), decided_by = auth.uid()
   WHERE user_id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION '신청서를 찾을 수 없습니다'; END IF;

  IF p_approve THEN
    UPDATE profiles SET can_lead = true,
           -- 지정하지 않으면 지금 역할을 그대로 둔다. 청소년 끗짱은 계속 청소년이다
           role = CASE WHEN p_adult IS NULL THEN role
                       WHEN p_adult THEN 'adult' ELSE 'youth' END
     WHERE id = p_user;
  ELSE
    UPDATE profiles SET can_lead = false WHERE id = p_user;
    -- 모집 중이던 루틴만 닫는다. 진행 중인 루틴과 아이들 기록은 안 건드린다
    UPDATE routines SET status = 'done'
     WHERE led_by = p_user AND status IN ('pending', 'recruit');
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION decide_kkut_application(uuid, boolean, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION decide_kkut_application(uuid, boolean, text, boolean) TO authenticated;
DROP FUNCTION IF EXISTS decide_kkut_application(uuid, boolean, text);

-- ── 6. 30일 조건을 없앤다 ──────────────────────────────
-- 14세 미만만 막는다. 나머지는 소속·나이·지원동기를 보고 사람이 판단한다
CREATE OR REPLACE FUNCTION kkut_eligibility()
RETURNS TABLE (days int, need int, invited boolean, eligible boolean) AS $$
  SELECT cert_days(), 0, true, true;   -- 조건 없음. days 는 화면에 참고로만
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION kkut_eligibility() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION kkut_eligibility() TO authenticated;

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
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS kkut_app_check ON kkut_applications;
CREATE TRIGGER kkut_app_check BEFORE INSERT OR UPDATE ON kkut_applications
  FOR EACH ROW EXECUTE FUNCTION check_kkut_application();

-- ── 7. 어른은 인증을 쌓을 수 없다 ──────────────────────
-- 도서기금은 청소년에게 쓰는 돈이다. 화면만 막으면 뚫린다.
-- 이미 쌓은 포인트와 교환권은 그대로 둔다 — 청소년일 때 읽어서 번 것이다
CREATE OR REPLACE FUNCTION check_cert_youth() RETURNS trigger AS $$
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;
  IF COALESCE((SELECT role FROM profiles WHERE id = NEW.user_id), 'youth') <> 'youth' THEN
    RAISE EXCEPTION '청소년만 인증할 수 있어요';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS certs_youth_only ON certifications;
CREATE TRIGGER certs_youth_only BEFORE INSERT ON certifications
  FOR EACH ROW EXECUTE FUNCTION check_cert_youth();

NOTIFY pgrst, 'reload schema';

-- ↓ 사람별 역할. 줄이 나와야 성공이다
SELECT u.email, p.name AS 이름, p.role AS 역할, p.can_lead AS 끗짱,
       (SELECT count(*) FROM certifications c WHERE c.user_id = p.id) AS 인증
  FROM profiles p JOIN auth.users u ON u.id = p.id ORDER BY p.role, p.name;
