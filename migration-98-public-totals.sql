-- 한끗독서 마이그레이션 98
-- 랜딩페이지 「지금까지 함께 만든 것」 — 누적 숫자 네 개
--
-- 【무엇을 내보내나】 참여 청소년 수, 끗짱 수, 인증 수, 읽은 책 권수. 사람 이름도 신상도 아닌 **합계뿐**이다.
--   로그인 전 방문자가 부른다.
--   · youth : 루틴에 참여(승인)한 청소년 수. 어른(role = 'adult')과 끗짱은 뺀다
--   · kkut  : 끗짱 수 (can_lead)
--   · certs : 인증 수. 사람×날짜 — 한 사람이 하루에 세 권을 읽어도 하루다 (dokseo_reading_stats 와 같은 기준)
--   · books : 인증에 적힌 서로 다른 책 제목 수
-- 기존 dokseo_reading_stats 는 건드리지 않는다 (앱 MY 의 「함께 쌓은 것」이 쓴다).

CREATE OR REPLACE FUNCTION dokseo_public_totals() RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'youth', COALESCE((
      SELECT count(DISTINCT rp.user_id)
        FROM routine_participants rp
        JOIN profiles p ON p.id = rp.user_id
       WHERE rp.status = 'approved'
         AND COALESCE(p.role, '') <> 'adult'
         AND NOT COALESCE(p.can_lead, false)), 0),
    'kkut',  COALESCE((SELECT count(*) FROM profiles WHERE COALESCE(can_lead, false)), 0),
    'certs', COALESCE((SELECT count(*) FROM (
                         SELECT DISTINCT user_id, cert_date FROM certifications) t), 0),
    'books', COALESCE((SELECT count(DISTINCT book_title) FROM certifications
                        WHERE book_title IS NOT NULL AND book_title <> ''), 0)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION dokseo_public_totals() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION dokseo_public_totals() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 함수를 실제로 불러 본다 (컬럼이 틀리면 여기서 오류가 난다)
SELECT dokseo_public_totals() AS 합계;
