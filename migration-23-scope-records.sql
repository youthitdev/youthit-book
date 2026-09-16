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
