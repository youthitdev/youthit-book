-- 한끗독서 마이그레이션 13
-- 포인트를 주는 곳을 넷으로
--
--   인증 1회        10P
--   댓글 1개         1P  (하루 5개까지 = 하루 최대 5P)
--   루틴 후기       30P  ← 화면은 아직 없음. 값만 미리 둔다
--   책인증후기      30P  ← 화면은 아직 없음
--
-- 【댓글 포인트 주의】
--   자기 인증에 스스로 단 댓글은 세지 않는다. 안 그러면 혼자서 하루 5P를
--   무한히 만들 수 있다.
--
-- 【문턱 계산】 15일을 하나도 안 빠지고 다 해도
--   인증 150P + 댓글 75P + 루틴 후기 30P = 255P 다.
--   책인증후기(30P)는 책을 받아야 쓸 수 있어 첫 교환권에는 못 쓴다.
--   지금 문턱 300P 로는 완주해도 첫 루틴에서 책을 못 받는다.
--   250P 로 내리려면:  UPDATE dokseo_settings SET points_per_voucher = 250 WHERE id = 1;

UPDATE dokseo_settings SET points_per_cert = 10 WHERE id = 1;
ALTER TABLE routines ALTER COLUMN points_per_cert SET DEFAULT 10;

ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_comment   int NOT NULL DEFAULT 1;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS comment_daily_cap    int NOT NULL DEFAULT 5;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_review    int NOT NULL DEFAULT 30;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_bookreview int NOT NULL DEFAULT 30;

COMMENT ON COLUMN dokseo_settings.points_per_comment    IS '댓글 1개당 포인트';
COMMENT ON COLUMN dokseo_settings.comment_daily_cap     IS '하루에 포인트를 주는 댓글 개수 상한';
COMMENT ON COLUMN dokseo_settings.points_per_review     IS '루틴 후기 1회 포인트 (화면 미구현)';
COMMENT ON COLUMN dokseo_settings.points_per_bookreview IS '책인증후기 1회 포인트 (화면 미구현)';

CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_cert int; v_cmt int; v_per int; v_ppc int; v_cap int;
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap
    INTO v_per, v_ppc, v_cap FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 300), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);

  -- 인증: 루틴을 가리지 않고 계정 전체
  SELECT COALESCE(sum(r.points_per_cert), 0) INTO v_cert
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

  v_points := v_cert + v_cmt;

  -- 정산 대기 중인 구매도 교환권을 이미 쓴 것으로 본다
  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',      v_points,
    'from_cert',   v_cert,
    'from_comment', v_cmt,
    'per_voucher', v_per,
    'earned',      v_earned,
    'used',        v_used,
    'left',        GREATEST(0, v_earned - v_used),
    'to_next',     v_per - (v_points % v_per)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION dokseo_points(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points(uuid) TO authenticated;
