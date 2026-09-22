-- 한끗독서 마이그레이션 35
-- 청소년 확인 서류
--
-- 왜 받나:
--   도서기금은 청소년에게 쓰는 돈이다. 기부금 사용명세에도 그렇게 적힌다.
--   그런데 가입할 때는 아무도 나이를 안 묻는다. 어른이 그냥 가입해서
--   포인트를 쌓고 교환권으로 책을 받을 수 있다.
--
-- 언제 막나 — 책을 받을 때다. 읽는 건 누구나 할 수 있어야 한다.
--   가입 직후부터 서류를 요구하면 시작을 못 한다. 돈이 나가는 순간에만
--   확인한다. 대신 포인트가 쌓이기 시작하면 미리 알린다 —
--   250P 를 채우고 나서야 "서류를 내세요" 는 늦다.
--
-- ⚠️ 개인정보다.
--   · 비공개 버킷. 본인과 운영진만 연다
--   · 승인하는 순간 파일을 지운다. 확인했다는 사실만 남긴다.
--     가지고 있는 것 자체가 위험이다
--   · 주민등록번호가 보이는 서류는 받지 않는다 (화면에서 안내)

-- ── 1. 컬럼 ───────────────────────────────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS verify_status   text NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS verify_doc_path text,
  ADD COLUMN IF NOT EXISTS verify_kind     text,
  ADD COLUMN IF NOT EXISTS verify_reason   text,
  ADD COLUMN IF NOT EXISTS verified_at     timestamptz;

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_verify_status_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_verify_status_check
  CHECK (verify_status IN ('none', 'pending', 'approved', 'rejected'));

COMMENT ON COLUMN profiles.verify_doc_path IS '비공개 버킷 경로. 승인하면 지운다 — 가지고 있는 것 자체가 위험이다';
COMMENT ON COLUMN profiles.verify_kind     IS '무엇으로 확인했는지 (학생증·청소년증·재학증명서…)';

-- ── 2. 서류 보관함 ─────────────────────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('dokseo-verify', 'dokseo-verify', false) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "dokseo_verify_own_insert" ON storage.objects;
CREATE POLICY "dokseo_verify_own_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'dokseo-verify' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "dokseo_verify_read" ON storage.objects;
CREATE POLICY "dokseo_verify_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'dokseo-verify' AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));

DROP POLICY IF EXISTS "dokseo_verify_delete" ON storage.objects;
CREATE POLICY "dokseo_verify_delete" ON storage.objects FOR DELETE
  USING (bucket_id = 'dokseo-verify' AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));

-- ── 3. 스스로 승인하지 못하게 ──────────────────────────
CREATE OR REPLACE FUNCTION check_profile_write() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.id         := OLD.id;
    NEW.role       := OLD.role;
    NEW.can_lead   := OLD.can_lead;
    NEW.created_at := OLD.created_at;
    NEW.verified_at := OLD.verified_at;
    NEW.verify_kind := OLD.verify_kind;
    -- 본인은 '내지 않음' 이나 '반려됨' 에서 '심사 중' 으로만 갈 수 있다
    IF NEW.verify_status <> OLD.verify_status THEN
      IF OLD.verify_status IN ('none', 'rejected') AND NEW.verify_status = 'pending' THEN
        NEW.verify_reason := NULL;
      ELSE
        NEW.verify_status := OLD.verify_status;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. 운영진이 확인한다 ───────────────────────────────
CREATE OR REPLACE FUNCTION decide_verify(
  p_user uuid, p_approve boolean, p_kind text DEFAULT NULL, p_reason text DEFAULT NULL
) RETURNS void AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;
  IF NOT p_approve AND COALESCE(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION '반려 사유를 적어주세요';
  END IF;

  IF p_approve THEN
    -- 파일 경로를 지운다. 실제 파일은 화면에서 지운 뒤 이걸 부른다
    UPDATE profiles
       SET verify_status = 'approved', verified_at = now(),
           verify_kind = COALESCE(btrim(p_kind), verify_kind, '확인함'),
           verify_doc_path = NULL, verify_reason = NULL
     WHERE id = p_user;
  ELSE
    UPDATE profiles
       SET verify_status = 'rejected', verify_reason = btrim(p_reason),
           verify_doc_path = NULL
     WHERE id = p_user;
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION '사람을 찾을 수 없습니다'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION decide_verify(uuid, boolean, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION decide_verify(uuid, boolean, text, text) TO authenticated;

-- 심사 대기 목록 (신청자 이름·경로. 운영진만)
CREATE OR REPLACE FUNCTION verify_queue()
RETURNS TABLE (user_id uuid, name text, region text, doc_path text, status text, reason text) AS $$
  SELECT p.id, p.name, p.region, p.verify_doc_path, p.verify_status, p.verify_reason
    FROM profiles p
   WHERE is_admin() AND p.verify_status IN ('pending', 'rejected')
   ORDER BY p.verify_status, p.name;
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION verify_queue() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION verify_queue() TO authenticated;

-- ── 5. 확인 전에는 책을 못 받는다 ──────────────────────
-- 화면만 막으면 뚫린다. 돈이 나가는 자리라 서버에서 건다
CREATE OR REPLACE FUNCTION check_purchase_verified() RETURNS trigger AS $$
DECLARE v text;
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;
  SELECT verify_status INTO v FROM profiles WHERE id = NEW.user_id;
  IF COALESCE(v, 'none') <> 'approved' THEN
    RAISE EXCEPTION '청소년 확인이 끝나야 책을 받을 수 있어요';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS purchases_verified ON book_purchases;
CREATE TRIGGER purchases_verified BEFORE INSERT ON book_purchases
  FOR EACH ROW EXECUTE FUNCTION check_purchase_verified();

NOTIFY pgrst, 'reload schema';

-- ↓ 사람별 확인 상태. 줄이 나와야 성공이다
SELECT u.email, p.name AS 이름, p.role AS 역할, p.verify_status AS 확인
  FROM profiles p JOIN auth.users u ON u.id = p.id ORDER BY p.verify_status, p.name;
