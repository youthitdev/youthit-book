-- 한끗독서 마이그레이션 147
-- 「매일 한끗」의 숫자를 일일·주간 리포트와 관리자 통계에 보여 준다 (2026-10-22 사용자)
--
-- 【왜 따로】 상시 루틴은 끝나는 날과 완주가 없어서 기존 루틴별 항목(인증률·완주·종료)에 섞으면 숫자가 어긋난다.
--   그래서 둘에서 모두 뺐고(145), 대신 「얼마나 쓰이나」를 보여 주는 별도 구역을 둔다. 닉네임은 넣지 않고 숫자만.
--
-- 【무엇을】
--   1. ongoing_stats(기준일): 상시 루틴의 숫자 묶음. 청소년 참여자만 센다(끗짱·운영진·탈퇴 제외).
--        people 참여 · did 기준일 인증 · streak3/seven 기준일에 끝나는 연속 3일·7일 이상 · avg_streak 지금 이어지는 연속의 평균
--        broke 전날 인증했는데 기준일엔 안 한 사람 · new_day/new_week 새 참여 · week_users/week_avg 최근 7일 인증한 사람·하루 평균
--        prev_week_users 그 전 7일 · cheers_day/cheers_week 응원 건수.  (리포트가 부른다. 앱에서는 못 부른다)
--   2. admin_ongoing_stats(): 관리자 통계 화면용. 오늘 기준.
--
-- ⚠️ 145·146 뒤에 돌린다. 여러 번 돌려도 된다. 그 뒤 143(리포트)을 다시 돌려야 리포트에 구역이 나온다.

CREATE OR REPLACE FUNCTION ongoing_stats(p_day date) RETURNS jsonb AS $$
DECLARE v_rid bigint; r jsonb;
BEGIN
  SELECT id INTO v_rid FROM routines WHERE ongoing AND status = 'active' ORDER BY id LIMIT 1;
  IF v_rid IS NULL THEN RETURN NULL; END IF;

  WITH u AS (   -- 참여한 청소년
    SELECT rp.user_id, (rp.joined_at AT TIME ZONE 'Asia/Seoul')::date AS jd
      FROM routine_participants rp JOIN profiles p ON p.id = rp.user_id
     WHERE rp.routine_id = v_rid AND rp.status = 'approved' AND p.withdrawn_at IS NULL
       AND COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
       AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id)
  ),
  d AS (SELECT DISTINCT c.user_id, c.cert_date FROM certifications c JOIN u ON u.user_id = c.user_id
         WHERE c.routine_id = v_rid AND c.cert_date <= p_day),
  g AS (SELECT d.user_id, d.cert_date, d.cert_date - (row_number() OVER (PARTITION BY d.user_id ORDER BY d.cert_date))::int AS grp FROM d),
  runs AS (SELECT g.user_id, count(*)::int AS n, max(g.cert_date) AS last_d FROM g GROUP BY g.user_id, g.grp),
  cur  AS (SELECT runs.user_id, runs.n FROM runs WHERE runs.last_d = p_day),
  cur2 AS (SELECT runs.user_id, runs.n FROM runs WHERE runs.last_d >= p_day - 1)
  SELECT jsonb_build_object(
    'people',          (SELECT count(*) FROM u),
    'did',             (SELECT count(*) FROM d WHERE d.cert_date = p_day),
    'streak3',         (SELECT count(*) FROM cur WHERE cur.n >= 3),
    'seven',           (SELECT count(*) FROM cur WHERE cur.n >= 7),
    'avg_streak',      COALESCE((SELECT round(avg(cur2.n)::numeric, 1) FROM cur2), 0),
    'broke',           (SELECT count(*) FROM d d1 WHERE d1.cert_date = p_day - 1
                          AND NOT EXISTS (SELECT 1 FROM d d2 WHERE d2.user_id = d1.user_id AND d2.cert_date = p_day)),
    'new_day',         (SELECT count(*) FROM u WHERE u.jd = p_day),
    'new_week',        (SELECT count(*) FROM u WHERE u.jd BETWEEN p_day - 6 AND p_day),
    'week_users',      (SELECT count(DISTINCT d.user_id) FROM d WHERE d.cert_date BETWEEN p_day - 6 AND p_day),
    'week_avg',        COALESCE((SELECT round(count(*)::numeric / 7, 1) FROM d WHERE d.cert_date BETWEEN p_day - 6 AND p_day), 0),
    'prev_week_users', (SELECT count(DISTINCT d.user_id) FROM d WHERE d.cert_date BETWEEN p_day - 13 AND p_day - 7),
    'cheers_day',      (SELECT count(*) FROM ongoing_cheers oc WHERE oc.routine_id = v_rid AND oc.day = p_day),
    'cheers_week',     (SELECT count(*) FROM ongoing_cheers oc WHERE oc.routine_id = v_rid AND oc.day BETWEEN p_day - 6 AND p_day)
  ) INTO r;
  RETURN r;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION ongoing_stats(date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION admin_ongoing_stats() RETURNS jsonb AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  RETURN ongoing_stats((now() AT TIME ZONE 'Asia/Seoul')::date);
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION admin_ongoing_stats() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_ongoing_stats() TO authenticated;

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 함수 2 · 지금 숫자 (상시 루틴이 있으면 숫자 묶음, 없으면 빈칸)
SELECT (SELECT count(*) FROM pg_proc WHERE proname IN ('ongoing_stats', 'admin_ongoing_stats')) AS 함수_2여야,
       admin_ongoing_stats()                                                                    AS 지금_숫자;
