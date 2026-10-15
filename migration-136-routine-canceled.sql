-- 한끗독서 마이그레이션 136
-- 루틴 「폐강」 — 인원이 모이지 않아 열리지 못한 루틴을 「완료」와 구분한다 (2026-10-15 사용자)
--
-- 【배경】 내부 기준으로는 4명 이상이 들어와야 루틴이 열리고, 시범 기간에는 3명까지 연다. 모자라 폐강한 루틴을 지금은 「종료」로 처리해서
--   통계에서 「완료 · 완주 0명 · 0%」로 잡혀 전체 완주율을 끌어내렸다. 실제로 진행된 적이 없는 루틴이다.
--
-- 【하는 일】
--   1) routines.canceled 칸을 둔다. 상태는 지금처럼 「완료(done)」로 두고(참여·인증을 막는 기존 처리 그대로) 폐강인지 아닌지만 따로 적는다.
--   2) admin_cancel_routine(루틴) — 종료 처리와 폐강 표시를 한 번에 하고, **승인되어 참여한 청소년**에게
--      「이번 루틴은 열리지 못했어요」 알림을 보낸다 (끗짱·탈퇴한 회원 제외, 끌 수 없는 알림).
--   3) 이미 종료 처리해 둔 두 루틴(「너의 오늘을 응원해」「나를 찾아 떠나는 책여행」)을 폐강으로 바꾸고 참여자에게 알린다.
--   4) 통계(admin_stats): 폐강은 「완료」와 완주율에서 빼고 따로 센다.
--
-- ⚠️ 135 뒤에 돌린다. 여러 번 돌려도 된다 (이미 폐강한 루틴은 다시 알리지 않는다). 3) 때문에 이 파일을 돌리면 그 두 루틴의 참여자에게 알림이 간다.

ALTER TABLE routines ADD COLUMN IF NOT EXISTS canceled boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN routines.canceled IS '인원이 모이지 않아 폐강한 루틴. 상태는 done 이고, 통계의 완주율에서 빠진다';

CREATE OR REPLACE FUNCTION admin_cancel_routine(p_id bigint) RETURNS int AS $$
DECLARE v_title text; v_n int := 0; u uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  SELECT title INTO v_title FROM routines
   WHERE id = p_id AND status IN ('recruit', 'active', 'done') AND NOT canceled;
  IF NOT FOUND THEN RAISE EXCEPTION '폐강할 수 없는 루틴이에요 (이미 폐강했거나 승인 대기 중이에요)'; END IF;

  UPDATE routines SET status = 'done', canceled = true WHERE id = p_id;

  FOR u IN
    SELECT rp.user_id FROM routine_participants rp JOIN profiles p ON p.id = rp.user_id
     WHERE rp.routine_id = p_id AND rp.status = 'approved'
       AND p.withdrawn_at IS NULL AND NOT COALESCE(p.can_lead, false)
  LOOP
    PERFORM notify_push(u, '이번 루틴은 열리지 못했어요',
      COALESCE(v_title, '루틴') || ' · 인원이 모이지 않아 이번에는 열리지 못했어요. 다음 루틴에서 만나요 🌱',
      '/youthit-book/app.html?tab=cert');
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION admin_cancel_routine(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_cancel_routine(bigint) TO authenticated;

-- ── 이미 종료해 둔 두 루틴을 폐강으로 (참여자에게 알림도 간다) ──
SELECT id AS 루틴, title AS 이름, admin_cancel_routine(id) AS 알림_보낸_수
  FROM routines
 WHERE status = 'done' AND NOT canceled
   AND title IN ('너의 오늘을 응원해', '나를 찾아 떠나는 책여행')
   AND start_date = '2026-10-15';

-- ── 통계: 폐강은 완료·완주율에서 빼고 따로 센다 ──
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
-- 아무것도 바꾸지 않는다. 기대: 함수 2 / 폐강 루틴 수 / 통계의 루틴 상태에 폐강이 따로 보인다
SELECT (SELECT count(*) FROM pg_proc WHERE proname IN ('admin_cancel_routine', 'admin_stats')) AS 함수_2이어야,
       (SELECT count(*) FROM routines WHERE canceled)                                          AS 폐강한_루틴,
       admin_stats() -> 'routines'                                                              AS 루틴_상태;
