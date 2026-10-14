-- 한끗독서 마이그레이션 133
-- 관리자 「통계」 화면 + 청소년 명단에 재학 상태(학교 밖 여부) (2026-10-14 사용자 — 한끗루틴 관리자의 통계처럼)
--
-- ── A. admin_stats() — 통계 화면이 한 번에 읽는 숫자 ────────────────
--   · 청소년 수(확인 완료, 재학 상태별), 끗짱 수(승인·대기), 루틴 상태별 수, 탈퇴 수(전체·최근 30일)
--   · 지역별(시·도) 청소년 수
--   · 루틴별 참여 인원·완주 인원·완주율
--
-- 【청소년으로 세는 사람】 역할이 청소년이고 끗짱이 아니며, 운영진이 아니고, 탈퇴하지 않았고, 끗짱 신청서가 없는 사람.
--   (어른은 가입하면 끗짱 신청서가 생기므로(132) 청소년 숫자에 섞이지 않는다)
--
-- 【완주의 기준】 그 루틴 기간(시작일~종료일) 일수의 p_pct %(기본 70%) 이상 인증한 날이 있으면 완주다.
--   인증은 하루에 한 번만 세고, 승인되어 참여한 청소년만 센다. 완주율은 **끝난(done) 루틴**만 합쳐 낸다 —
--   아직 진행 중인 루틴은 끝나지 않았으니 완주를 말할 수 없다. 기준을 바꾸려면 아래 함수의 기본값(70)을 고친다.
--
-- ── B. verify_queue() — 명단에 재학 상태(school) 칸을 보탠다 ─────────
--   가입할 때 고른 「재학 · 학교밖 · 졸업 · 기타」다. 본인이 고른 값이라 운영진이 서류로 확인한 것은 아니다.
--
-- ⚠️ 48·123·132 뒤에 돌린다. 여러 번 돌려도 된다.

-- ── B ──────────────────────────────────────────────────
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
  cert_count   int,
  school       text
) AS $$
  SELECT p.id, p.name, p.nick, p.region,
         pp.birth_date, age_years(pp.birth_date),
         u.email::text, pp.phone,
         p.role, p.can_lead,
         p.verify_doc_path, p.verify_status, p.verify_reason,
         p.verify_kind, p.verified_at, p.created_at,
         u.last_sign_in_at,
         c.last_on, COALESCE(c.n, 0)::int,
         p.school_status
    FROM profiles p
    LEFT JOIN profiles_private pp ON pp.id = p.id
    LEFT JOIN auth.users        u  ON u.id  = p.id
    LEFT JOIN LATERAL (
      SELECT max(cert_date) AS last_on, count(*) AS n
        FROM certifications WHERE user_id = p.id
    ) c ON true
   WHERE is_admin()
   ORDER BY CASE COALESCE(p.verify_status, 'none')
              WHEN 'pending'  THEN 0
              WHEN 'rejected' THEN 1
              WHEN 'none'     THEN 2
              ELSE 3
            END,
            p.created_at DESC;
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION verify_queue() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION verify_queue() TO authenticated;

-- ── A ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_stats(p_pct int DEFAULT 70) RETURNS jsonb AS $$
DECLARE
  v_pct   int := LEAST(GREATEST(COALESCE(p_pct, 70), 1), 100);
  v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  r jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  WITH y AS (
    SELECT p.id, p.verify_status, NULLIF(btrim(COALESCE(p.school_status, '')), '') AS school,
           NULLIF(btrim(COALESCE(p.region, '')), '') AS region
      FROM profiles p
     WHERE COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false) AND p.withdrawn_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id)
       AND NOT EXISTS (SELECT 1 FROM kkut_applications k WHERE k.user_id = p.id)
  ),
  rt AS (
    SELECT ro.id, ro.title, ro.status, ro.start_date, ro.end_date,
           GREATEST((ro.end_date - ro.start_date) + 1, 1) AS days,
           (SELECT count(*) FROM routine_participants rp WHERE rp.routine_id = ro.id AND rp.status = 'approved') AS people
      FROM routines ro
     WHERE ro.status IN ('recruit', 'active', 'done')
  ),
  fin AS (   -- 참여자별 인증한 날 수
    SELECT rp.routine_id, rp.user_id,
           (SELECT count(DISTINCT c.cert_date) FROM certifications c
             WHERE c.routine_id = rp.routine_id AND c.user_id = rp.user_id) AS n
      FROM routine_participants rp WHERE rp.status = 'approved'
  ),
  rr AS (
    SELECT rt.*,
           (SELECT count(*) FROM fin WHERE fin.routine_id = rt.id AND fin.n >= CEIL(rt.days * v_pct / 100.0)) AS done_n,
           (SELECT count(DISTINCT c.user_id) FROM certifications c WHERE c.routine_id = rt.id AND c.cert_date = v_today) AS today_n
      FROM rt
  )
  SELECT jsonb_build_object(
    'pct', v_pct,
    'youth', jsonb_build_object(
      'total',    (SELECT count(*) FROM y),
      'verified', (SELECT count(*) FROM y WHERE verify_status = 'approved'),
      'school',   COALESCE((SELECT jsonb_object_agg(k, n) FROM (SELECT COALESCE(school, '미입력') AS k, count(*) AS n FROM y GROUP BY 1) s), '{}'::jsonb),
      'region',   COALESCE((SELECT jsonb_agg(jsonb_build_object('r', k, 'n', n) ORDER BY n DESC, k)
                              FROM (SELECT COALESCE(split_part(region, ' ', 1), '미입력') AS k, count(*) AS n FROM y GROUP BY 1) g), '[]'::jsonb)
    ),
    'kkut', jsonb_build_object(
      'total',   (SELECT count(*) FROM profiles p WHERE COALESCE(p.can_lead, false) AND p.withdrawn_at IS NULL
                    AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id)),
      'pending', (SELECT count(*) FROM kkut_applications WHERE status = 'pending')
    ),
    'routines', jsonb_build_object(
      'recruit', (SELECT count(*) FROM routines WHERE status = 'recruit'),
      'active',  (SELECT count(*) FROM routines WHERE status = 'active'),
      'done',    (SELECT count(*) FROM routines WHERE status = 'done'),
      'other',   (SELECT count(*) FROM routines WHERE status NOT IN ('recruit', 'active', 'done'))
    ),
    'withdrawn', jsonb_build_object(
      'total',  (SELECT count(*) FROM profiles WHERE withdrawn_at IS NOT NULL),
      'recent', (SELECT count(*) FROM profiles WHERE withdrawn_at >= now() - interval '30 days')
    ),
    'rows', COALESCE((SELECT jsonb_agg(jsonb_build_object(
              'id', id, 'title', title, 'status', status, 'start', start_date, 'end', end_date,
              'days', days, 'people', people, 'done', done_n, 'today', today_n)
              ORDER BY CASE status WHEN 'active' THEN 0 WHEN 'recruit' THEN 1 ELSE 2 END, start_date DESC)
              FROM rr), '[]'::jsonb)
  ) INTO r;
  RETURN r;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION admin_stats(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_stats(int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 바꾸는 것 없이 읽는다. 기대: 명단 함수에 school 칸 1 / 통계가 나온다 (아래 숫자를 화면과 맞춰 보세요)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'verify_queue'
          AND pg_get_function_result(oid) LIKE '%school%')                       AS 명단_재학칸_1이어야,
       admin_stats() -> 'youth' -> 'total'                                       AS 청소년,
       admin_stats() -> 'youth' -> 'school'                                      AS 재학_상태별,
       admin_stats() -> 'kkut' -> 'total'                                        AS 끗짱,
       admin_stats() -> 'routines'                                               AS 루틴_상태;
