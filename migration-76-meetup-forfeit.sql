-- 한끗독서 마이그레이션 76
-- 공유회에 안 오면 그 루틴에서 모은 포인트는 쓸 수 없다
--
-- 공유회가 걸린 루틴은 그 자리가 반이다. 읽기만 하고 안 오면 반쪽이라,
-- 모은 포인트도 그 루틴에서는 쓸 수 없게 한다.
--
-- 【지우지 않는다. 세지 않을 뿐이다】 기록은 그대로 남고, 포인트는 계산할
--   때 빠진다. 끗짱이 참석을 늦게 체크하면 그 순간 도로 들어온다 —
--   남의 깜빡임으로 아이가 영영 막히면 안 된다.
--
-- 【언제부터 빠지나】 공유회 시각이 지났는데 참석 표시(met_at)가 없을 때.
--   그 전에는 그대로 쌓인다.
--
-- 【무엇이 빠지나】 그 루틴의 인증 포인트와 공유회 포인트. 댓글·후기·
--   이정표는 계정 전체에 걸린 것이라 건드리지 않는다. 읽은 날을 세는
--   숫자(누적 인증)도 그대로다 — 아이가 읽은 날은 읽은 날이다.
--
-- ⚠️ dokseo_points 는 12 → 13 → 24 → 31 → 69 로 덮어써졌다. 지금 살아
--   있는 것은 69번 판이고, 이 파일은 거기에 이 조건만 더한 것이다.

-- ── 공유회를 지나쳐 버렸나 ─────────────────────────────
-- 공유회 시각이 지났는데 참석 표시가 없으면 참이다.
-- 끗짱이 뒤늦게 체크하면 이 값이 거짓으로 돌아오고, 포인트도 같이 돌아온다
CREATE OR REPLACE FUNCTION meetup_missed(p_routine bigint, p_user uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM routines r
      LEFT JOIN routine_participants rp
             ON rp.routine_id = r.id AND rp.user_id = p_user
     WHERE r.id = p_routine
       AND r.meetup_required
       AND r.meetup_at IS NOT NULL
       AND r.meetup_at < now()
       AND rp.met_at IS NULL
  );
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int; v_rev int; v_meet int;
  v_lost int;
  v_per int; v_ppc int; v_cap int; v_pm int; v_ms int[]; v_pr int; v_pb int; v_pmt int;
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap,
         points_per_milestone, bonus_milestones,
         points_per_review, points_per_bookreview, points_per_meetup
    INTO v_per, v_ppc, v_cap, v_pm, v_ms, v_pr, v_pb, v_pmt
    FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 250), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);
  v_pm  := COALESCE(v_pm, 10);
  v_ms  := COALESCE(v_ms, '{10,30,66,100,200}');
  v_pr  := COALESCE(v_pr, 30);
  v_pb  := COALESCE(v_pb, 30);
  v_pmt := COALESCE(v_pmt, 50);

  -- 하루에 한 번이다. 같은 날 세 권을 읽어도 그날치 한 번.
  -- 공유회를 지나쳐 버린 루틴은 여기서 빠진다
  SELECT COALESCE(sum(ppc), 0) INTO v_cert FROM (
    SELECT max(r.points_per_cert) AS ppc
      FROM certifications c JOIN routines r ON r.id = c.routine_id
     WHERE c.user_id = v_u
       AND NOT meetup_missed(r.id, v_u)
     GROUP BY c.routine_id, c.cert_date) t;

  -- 못 간 루틴에서 날아간 몫. 화면에 「얼마가 묶였는지」를 말해 주려는 것이다
  SELECT COALESCE(sum(ppc), 0) INTO v_lost FROM (
    SELECT max(r.points_per_cert) AS ppc
      FROM certifications c JOIN routines r ON r.id = c.routine_id
     WHERE c.user_id = v_u
       AND meetup_missed(r.id, v_u)
     GROUP BY c.routine_id, c.cert_date) t;

  -- 읽은 날은 읽은 날이다. 이정표는 그대로 센다
  SELECT count(DISTINCT cert_date) INTO v_n FROM certifications WHERE user_id = v_u;

  SELECT COALESCE(sum(LEAST(n, v_cap)), 0) * v_ppc INTO v_cmt
    FROM (
      SELECT count(*) AS n
        FROM cert_comments m JOIN certifications c ON c.id = m.cert_id
       WHERE m.user_id = v_u AND c.user_id <> v_u
       GROUP BY (m.created_at AT TIME ZONE 'Asia/Seoul')::date
    ) t;

  SELECT COALESCE(count(*), 0) * v_pm INTO v_bonus FROM unnest(v_ms) m WHERE m <= v_n;
  SELECT min(m) INTO v_next FROM unnest(v_ms) m WHERE m > v_n;

  SELECT COALESCE(count(*) FILTER (WHERE kind = 'routine'), 0) * v_pr
       + COALESCE(count(*) FILTER (WHERE kind = 'book'),    0) * v_pb
    INTO v_rev FROM reviews WHERE user_id = v_u;

  SELECT COALESCE(count(*), 0) * v_pmt INTO v_meet
    FROM routine_participants rp
    JOIN routines ro ON ro.id = rp.routine_id
   WHERE rp.user_id = v_u AND rp.met_at IS NOT NULL AND ro.meetup_required;

  v_points := v_cert + v_cmt + v_bonus + v_rev + v_meet;

  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',       v_points,
    'cert_count',   v_n,
    'from_cert',    v_cert,
    'from_comment', v_cmt,
    'from_bonus',   v_bonus,
    'from_review',  v_rev,
    'from_meetup',  v_meet,
    'lost_meetup',  v_lost,
    'next_milestone', v_next,
    'per_voucher',  v_per,
    'earned',       v_earned,
    'used',         v_used,
    'left',         GREATEST(0, v_earned - v_used),
    'to_next',      v_per - (v_points % v_per)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION dokseo_points(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points(uuid) TO authenticated;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'meetup_missed') AS 판별함수,
       CASE WHEN pg_get_functiondef((SELECT oid FROM pg_proc WHERE proname = 'dokseo_points'))
                 LIKE '%meetup_missed%' THEN '반영됨' ELSE '아직' END AS 포인트함수;
