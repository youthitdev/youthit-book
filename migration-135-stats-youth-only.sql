-- 한끗독서 마이그레이션 135
-- 통계의 루틴별 참여·완주 숫자에서 끗짱을 뺀다 (2026-10-14 사용자)
--
-- 【하는 일】 admin_stats() 가 루틴마다 세는 「참여 인원」「완주 인원」「오늘 인증」에서 끗짱(권한이 있는 사람)을 제외한다.
--   청소년만 센다. 나머지 숫자(청소년·끗짱·탈퇴·지역·재학 상태)는 그대로다.
--
-- ⚠️ 133 뒤에 돌린다 (133 의 함수를 이 판으로 바꾼다). 여러 번 돌려도 된다.

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
           (SELECT count(*) FROM routine_participants rp JOIN profiles pp ON pp.id = rp.user_id
             WHERE rp.routine_id = ro.id AND rp.status = 'approved' AND NOT COALESCE(pp.can_lead, false)) AS people
      FROM routines ro
     WHERE ro.status IN ('recruit', 'active', 'done')
  ),
  fin AS (   -- 참여자별 인증한 날 수
    SELECT rp.routine_id, rp.user_id,
           (SELECT count(DISTINCT c.cert_date) FROM certifications c
             WHERE c.routine_id = rp.routine_id AND c.user_id = rp.user_id) AS n
      FROM routine_participants rp JOIN profiles pp ON pp.id = rp.user_id
     WHERE rp.status = 'approved' AND NOT COALESCE(pp.can_lead, false)
  ),
  rr AS (
    SELECT rt.*,
           (SELECT count(*) FROM fin WHERE fin.routine_id = rt.id AND fin.n >= CEIL(rt.days * v_pct / 100.0)) AS done_n,
           (SELECT count(DISTINCT c.user_id) FROM certifications c JOIN profiles pp ON pp.id = c.user_id
             WHERE c.routine_id = rt.id AND c.cert_date = v_today AND NOT COALESCE(pp.can_lead, false)) AS today_n
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
-- 아무것도 바꾸지 않는다. 기대: 새 판 1 / 루틴별 참여 인원이 끗짱을 뺀 값으로 나온다
SELECT count(*) AS 새_판_1이어야 FROM pg_proc
 WHERE proname = 'admin_stats' AND pg_get_functiondef(oid) LIKE '%NOT COALESCE(pp.can_lead%';
SELECT r->>'title' AS 루틴, r->>'status' AS 상태, r->>'people' AS 참여_인원, r->>'done' AS 완주_인원
  FROM jsonb_array_elements(admin_stats() -> 'rows') r;
