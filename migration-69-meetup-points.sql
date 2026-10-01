-- 한끗독서 마이그레이션 69
-- 공유회에 오면 +50P
--
-- 지금까지 공유회는 조건이기만 했다 — 와야 책을 받는다. 그런데 오는 데도
-- 품이 든다(차비, 시간, 낯선 자리). 조건만 걸면 「안 오면 못 받는다」로만
-- 읽힌다. 오면 더 받는 쪽으로 돌려 세운다.
--
-- 【왜 인증 포인트를 2배로 하지 않나】 2배는 오기 전에 다 준다. 마지막 날이면
--   이미 다 모은 상태라 「와야 쓸 수 있다」가 번 걸 인질 잡는 꼴이 되고,
--   포인트만 보고 들어와 당일 안 나오는 길이 생긴다. 끗짱은 자리를 잡아놨는데.
--   무엇보다 거의 모든 아이에게 교환권이 2장이 되어 도서기금이 2배로 마른다.
--   이건 포인트 설계가 아니라 예산 결정이다.
--
-- 【조건은 그대로다】 met_at 이 없으면 책을 못 받는 건 변함없다(58번).
--   여기 더하는 건 포인트다.
--
-- ⚠️ dokseo_points 는 12 → 13 → 24 → 31 로 덮어써졌다. 지금 살아 있는 것은
--   31번 판이고, 이 파일은 거기에 공유회 몫만 더한 것이다.

ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS points_per_meetup int NOT NULL DEFAULT 50;
COMMENT ON COLUMN dokseo_settings.points_per_meetup IS '공유회에 참석하면 주는 포인트';

CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int; v_rev int; v_meet int;
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
  -- 루틴마다 points_per_cert 가 달라서 (루틴, 날짜)로 묶어 더한다
  SELECT COALESCE(sum(ppc), 0) INTO v_cert FROM (
    SELECT max(r.points_per_cert) AS ppc
      FROM certifications c JOIN routines r ON r.id = c.routine_id
     WHERE c.user_id = v_u
     GROUP BY c.routine_id, c.cert_date) t;

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

  -- 공유회: 끗짱이 「왔어요」로 표시한 루틴마다 한 번
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
SELECT points_per_meetup AS 공유회_포인트,
       points_per_voucher AS 교환권_문턱,
       (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_points') AS 포인트함수
  FROM dokseo_settings WHERE id = 1;
