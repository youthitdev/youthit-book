-- ────────────────────────────────────────────────────────────────────
-- 42. 청소년 확인을 「명단」으로
--
--   verify_queue() 가 서류를 낸 사람(pending·rejected)만 돌려줬다.
--   아무도 안 내면 관리자 화면이 빈 채로 있고, 운영진이 이미 아는 아이도
--   확인 처리할 길이 없었다.
--
--   전체 명단 + 각자의 상태를 돌려준다. 기다리는 사람이 먼저 온다.
--
--   나이는 profiles_private 에 있다 (41번). 이 함수는 SECURITY DEFINER 라
--   RLS 를 지나서 읽는다 — 그래서 운영진 화면에서만 보인다.
--
--   ⚠️ 돌려주는 모양이 바뀌므로 먼저 지워야 한다. CREATE OR REPLACE 로는 안 된다.
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS verify_queue();

CREATE FUNCTION verify_queue()
RETURNS TABLE (
  user_id     uuid,
  name        text,
  nick        text,
  region      text,
  age         int,
  role        text,
  can_lead    boolean,
  doc_path    text,
  status      text,
  reason      text,
  verify_kind text,
  verified_at timestamptz,
  joined_at   timestamptz
) AS $$
  SELECT p.id, p.name, p.nick, p.region,
         age_years(pp.birth_date),
         p.role, p.can_lead,
         p.verify_doc_path, p.verify_status, p.verify_reason,
         p.verify_kind, p.verified_at, p.created_at
    FROM profiles p
    LEFT JOIN profiles_private pp ON pp.id = p.id
   WHERE is_admin()
   ORDER BY CASE COALESCE(p.verify_status, 'none')
              WHEN 'pending'  THEN 0     -- 지금 손이 필요한 사람
              WHEN 'rejected' THEN 1
              WHEN 'none'     THEN 2
              ELSE 3                     -- 확인 끝난 사람은 맨 아래
            END,
            p.created_at DESC;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION verify_queue() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION verify_queue() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- SQL 편집기에서는 auth.uid() 가 없어 is_admin() 이 false 다. 0줄이 정상.
-- 함수가 제대로 섰는지는 돌려주는 칸으로 본다
SELECT pg_get_function_result('verify_queue'::regproc) AS 돌려주는_모양;
