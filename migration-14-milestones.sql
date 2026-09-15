-- 한끗독서 마이그레이션 14
-- 교환권 문턱 250P + 누적 인증 마일스톤 보너스
--
--   누적 10일 / 30일 / 66일 / 100일 / 200일 에 도달하면 각각 +10P.
--   '연속'이 아니라 '누적'이다. 하루 빠져도 잃는 게 없어야 한다 —
--   포인트를 계정에 쌓기로 한 것과 같은 이유다.
--
--   마일스톤은 배열이라 코드를 고치지 않고 늘릴 수 있다:
--     UPDATE dokseo_settings SET bonus_milestones = '{10,30,66,100,200,365}' WHERE id = 1;

UPDATE dokseo_settings SET points_per_voucher = 250 WHERE id = 1;

ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS bonus_milestones    int[] NOT NULL DEFAULT '{10,30,66,100,200}';
ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS points_per_milestone int  NOT NULL DEFAULT 10;

COMMENT ON COLUMN dokseo_settings.bonus_milestones     IS '누적 인증 일수 마일스톤. 도달할 때마다 보너스';
COMMENT ON COLUMN dokseo_settings.points_per_milestone IS '마일스톤 하나당 보너스 포인트';

CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int;
  v_per int; v_ppc int; v_cap int; v_pm int; v_ms int[];
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap,
         points_per_milestone, bonus_milestones
    INTO v_per, v_ppc, v_cap, v_pm, v_ms
    FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 250), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);
  v_pm  := COALESCE(v_pm, 10);
  v_ms  := COALESCE(v_ms, '{10,30,66,100,200}');

  -- 인증: 루틴을 가리지 않고 계정 전체
  SELECT count(*), COALESCE(sum(r.points_per_cert), 0) INTO v_n, v_cert
    FROM certifications c JOIN routines r ON r.id = c.routine_id
   WHERE c.user_id = v_u;

  -- 댓글: 하루 상한까지만. 자기 인증에 스스로 단 건 빼고
  SELECT COALESCE(sum(LEAST(n, v_cap)), 0) * v_ppc INTO v_cmt
    FROM (
      SELECT count(*) AS n
        FROM cert_comments m JOIN certifications c ON c.id = m.cert_id
       WHERE m.user_id = v_u AND c.user_id <> v_u
       GROUP BY (m.created_at AT TIME ZONE 'Asia/Seoul')::date
    ) t;

  -- 마일스톤: 지나온 개수만큼
  SELECT COALESCE(count(*), 0) * v_pm INTO v_bonus FROM unnest(v_ms) m WHERE m <= v_n;
  SELECT min(m) INTO v_next FROM unnest(v_ms) m WHERE m > v_n;

  v_points := v_cert + v_cmt + v_bonus;

  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',       v_points,
    'cert_count',   v_n,
    'from_cert',    v_cert,
    'from_comment', v_cmt,
    'from_bonus',   v_bonus,
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
