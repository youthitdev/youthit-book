-- ────────────────────────────────────────────────────────────────────
-- 48. 명단에 최근 활동을 보탠다
--
--   가입일만 있어서, 가입만 하고 한 번도 안 들어온 사람과 매일 읽는 사람이
--   똑같이 보였다. 청소년 확인을 판단할 때도 「이 사람이 실제로 쓰고 있나」가
--   재료가 된다.
--
--   최근 접속은 auth.users.last_sign_in_at,
--   마지막 인증은 certifications 에서 가져온다.
--   둘 다 보통은 못 읽는 자리다 — is_admin() 과 REVOKE 가 지키는 함수다.
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS verify_queue();

CREATE FUNCTION verify_queue()
RETURNS TABLE (
  user_id      uuid,
  name         text,
  nick         text,
  region       text,
  birth_date   date,
  age          int,
  email        text,
  phone        text,
  role         text,
  can_lead     boolean,
  doc_path     text,
  status       text,
  reason       text,
  verify_kind  text,
  verified_at  timestamptz,
  joined_at    timestamptz,
  last_seen_at timestamptz,
  last_cert_on date,
  cert_count   int
) AS $$
  SELECT p.id, p.name, p.nick, p.region,
         pp.birth_date, age_years(pp.birth_date),
         u.email::text, pp.phone,
         p.role, p.can_lead,
         p.verify_doc_path, p.verify_status, p.verify_reason,
         p.verify_kind, p.verified_at, p.created_at,
         u.last_sign_in_at,
         c.last_on, COALESCE(c.n, 0)::int
    FROM profiles p
    LEFT JOIN profiles_private pp ON pp.id = p.id
    LEFT JOIN auth.users        u  ON u.id  = p.id
    LEFT JOIN LATERAL (
      SELECT max(cert_date) AS last_on, count(*) AS n
        FROM certifications WHERE user_id = p.id
    ) c ON true
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
SELECT pg_get_function_result('verify_queue'::regproc) AS 돌려주는_모양;
