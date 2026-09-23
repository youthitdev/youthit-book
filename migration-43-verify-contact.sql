-- ────────────────────────────────────────────────────────────────────
-- 43. 명단에 판단할 재료를 넣는다
--
--   42 는 이름·닉네임·지역·만나이만 줬다. 「이 사람이 청소년이 맞나」를
--   보는 자리인데 재료가 모자랐고, 돌려보낸 뒤 연락할 방법도 없었다.
--
--   더하는 것: 생년월일(날짜) · 이메일 · 휴대폰
--
--   이메일은 auth.users 에, 휴대폰·생년월일은 profiles_private 에 있다.
--   둘 다 보통은 못 읽는 자리다 — 이 함수가 SECURITY DEFINER 이고
--   첫 줄에서 is_admin() 을 보기 때문에 운영진에게만 열린다.
--
--   ⚠️ anon·authenticated 가 직접 못 부르게 막는 REVOKE 가 생명줄이다.
--      빠지면 아이들 연락처가 통째로 열린다.
-- ────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS verify_queue();

CREATE FUNCTION verify_queue()
RETURNS TABLE (
  user_id     uuid,
  name        text,
  nick        text,
  region      text,
  birth_date  date,
  age         int,
  email       text,
  phone       text,
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
         pp.birth_date, age_years(pp.birth_date),
         u.email::text, pp.phone,
         p.role, p.can_lead,
         p.verify_doc_path, p.verify_status, p.verify_reason,
         p.verify_kind, p.verified_at, p.created_at
    FROM profiles p
    LEFT JOIN profiles_private pp ON pp.id = p.id
    LEFT JOIN auth.users        u  ON u.id  = p.id
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
