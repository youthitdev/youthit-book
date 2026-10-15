-- 한끗독서 마이그레이션 137
-- 통계에 「전체 인증 수」를 더한다 (2026-10-15 사용자)
--
-- 【하는 일】 admin_stats() 결과에 certs 를 보탠다.
--   · total  올라온 인증 전체 건수 (청소년·끗짱 모두, 사진과 글이 지워진 인증도 기록으로 센다)
--   · days   하루 한 번만 센 인증 (같은 사람이 같은 루틴에서 같은 날 올린 것은 하나) — 나다움·완주 계산과 같은 방식
--   · kkut   그중 끗짱이 올린 건수
--   · month  이번 달(한국 시간)에 올라온 건수
--   나머지 숫자는 136 판과 같다.
--
-- ⚠️ 136 뒤에 돌린다. 여러 번 돌려도 된다. 아무것도 바꾸지 않는다 (함수만 바꾼다).

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
    SELECT ro.id, ro.title, ro.status, ro.canceled, ro.start_date, ro.end_date,
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
      'done',    (SELECT count(*) FROM routines WHERE status = 'done' AND NOT canceled),
      'canceled', (SELECT count(*) FROM routines WHERE canceled),
      'other',   (SELECT count(*) FROM routines WHERE status NOT IN ('recruit', 'active', 'done'))
    ),
    'certs', jsonb_build_object(
      'total', (SELECT count(*) FROM certifications),
      'days',  (SELECT count(*) FROM (SELECT DISTINCT user_id, routine_id, cert_date FROM certifications) d),
      'kkut',  (SELECT count(*) FROM certifications c JOIN profiles pp ON pp.id = c.user_id WHERE COALESCE(pp.can_lead, false)),
      'month', (SELECT count(*) FROM certifications WHERE (created_at AT TIME ZONE 'Asia/Seoul')::date >= date_trunc('month', (now() AT TIME ZONE 'Asia/Seoul'))::date)
    ),
    'withdrawn', jsonb_build_object(
      'total',  (SELECT count(*) FROM profiles WHERE withdrawn_at IS NOT NULL),
      'recent', (SELECT count(*) FROM profiles WHERE withdrawn_at >= now() - interval '30 days')
    ),
    'rows', COALESCE((SELECT jsonb_agg(jsonb_build_object(
              'id', id, 'title', title, 'status', status, 'canceled', canceled, 'start', start_date, 'end', end_date,
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
SELECT admin_stats() -> 'certs' AS 인증_숫자;
