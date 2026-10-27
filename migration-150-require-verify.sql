-- 한끗독서 마이그레이션 150
-- 청소년 확인을 하지 않은 청소년은 루틴에 참여하거나 인증할 수 없다 (2026-10-27 사용자)
--
-- 【바뀌는 것】 전에는 확인을 책 받을 때만 물었다(migration-82·88). 이제 **참여 신청과 인증 전에** 묻는다.
--   · 막는 사람: 청소년(role = youth)이면서 끗짱이 아니고, 확인 상태가 「안 냄(none)」 또는 「반려(rejected)」인 사람
--   · 통과하는 사람: 서류를 낸 사람(pending — 운영진이 보는 중)과 확인이 끝난 사람(approved). 확인이 오래 걸려도 아이가 기다리지 않게 한다
--   · 운영진 계정·끗짱·어른은 막지 않는다
--   · 이미 진행 중인 루틴의 미확인 청소년도 **다음 인증부터** 막힌다. 그 전에 몇 명인지 아래 맨 끝 조회로 본다
--
-- 【끄는 스위치】 문제가 생기면 한 줄로 끈다:  UPDATE dokseo_settings SET require_verify = false WHERE id = 1;
--   다시 켜기:  UPDATE dokseo_settings SET require_verify = true WHERE id = 1;
--
-- 기존 함수(check_participant_insert · check_cert_youth · check_cert_started)는 건드리지 않고
-- 새 검사 하나를 참여·인증 앞에 따로 둔다.
--
-- ⚠️ 여러 번 돌려도 된다.

ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS require_verify boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN dokseo_settings.require_verify IS '켜 두면 청소년 확인(서류 제출) 전에는 루틴 참여·인증을 막는다';

-- 이 사람이 지금 막혀야 하는가 (프로필만 본다 — 운영진 예외는 트리거에서)
CREATE OR REPLACE FUNCTION youth_needs_verify(p_user uuid) RETURNS boolean AS $$
  SELECT COALESCE((SELECT require_verify FROM dokseo_settings WHERE id = 1), true)
     AND EXISTS (SELECT 1 FROM profiles p
                  WHERE p.id = p_user
                    AND COALESCE(p.role, 'youth') = 'youth'
                    AND NOT COALESCE(p.can_lead, false)
                    AND COALESCE(p.verify_status, 'none') NOT IN ('pending', 'approved'));
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

CREATE OR REPLACE FUNCTION check_verified_for_routine() RETURNS trigger AS $$
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;
  IF youth_needs_verify(NEW.user_id) THEN
    RAISE EXCEPTION '청소년 확인을 먼저 해 주세요. MY에서 서류를 올리면 돼요';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS parts_verified_only ON routine_participants;
CREATE TRIGGER parts_verified_only BEFORE INSERT ON routine_participants
  FOR EACH ROW EXECUTE FUNCTION check_verified_for_routine();

DROP TRIGGER IF EXISTS certs_verified_only ON certifications;
CREATE TRIGGER certs_verified_only BEFORE INSERT ON certifications
  FOR EACH ROW EXECUTE FUNCTION check_verified_for_routine();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 검사가 둘 붙었는지, 지금 모집·진행 중인 루틴에서 다음 인증부터 막히는 사람이 몇 명인지 (이름은 안 나온다)
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname IN ('parts_verified_only', 'certs_verified_only')) AS 검사_2여야,
       (SELECT require_verify FROM dokseo_settings WHERE id = 1)                                          AS 켜짐,
       (SELECT count(DISTINCT rp.user_id)
          FROM routine_participants rp JOIN routines r ON r.id = rp.routine_id
         WHERE rp.status = 'approved' AND r.status IN ('recruit', 'active')
           AND youth_needs_verify(rp.user_id))                                                           AS 막히는_참여자;
