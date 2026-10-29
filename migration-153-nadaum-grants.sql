-- 한끗독서 마이그레이션 153
-- 운영진이 나다움을 손으로 지급한다 (2026-10-29 요청: 한끗루틴처럼)
--
-- 【정해진 것】
--   · 관리자 화면 「나다움 지급」 탭에서 청소년을 골라 N 을 준다. 사유는 꼭 적는다(받는 아이에게 알림으로 간다).
--   · 한 번에 1~1000N. 더 줄 일이 있으면 나눠서 준다 — 숫자를 잘못 눌러도 교환권이 한꺼번에 쏟아지지 않게.
--   · 잘못 준 것은 「회수」한다. 줄을 지우지 않고 회수 표시만 남겨 누가 언제 무엇을 했는지 기록이 남는다.
--   · 받은 나다움은 인증·댓글·후기와 같은 합계에 들어가 교환권 계산도 같이 된다(150N 마다 1장).
--   · 청소년에게만 줄 수 있다(끗짱·어른·탈퇴 회원 제외).
--
-- 【무엇을】
--   1. nadaum_grants 표 — 본인과 운영진만 읽는다. 쓰기는 아래 함수로만 한다
--   2. grant_nadaum(청소년, 숫자, 사유) / void_nadaum(번호, 사유) — 운영진만
--   3. dokseo_points: 합계에 손으로 준 몫(from_manual)을 더한다 — 151번의 식에 한 덩어리만 더했다
--
-- ⚠️ 151(dokseo_points) 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS nadaum_grants (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id     uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  amount      int    NOT NULL CHECK (amount BETWEEN 1 AND 1000),
  reason      text   NOT NULL,
  granted_by  uuid,
  created_at  timestamptz NOT NULL DEFAULT now(),
  voided_at   timestamptz,
  voided_by   uuid,
  void_reason text
);
CREATE INDEX IF NOT EXISTS nadaum_grants_user_idx ON nadaum_grants (user_id) WHERE voided_at IS NULL;

ALTER TABLE nadaum_grants ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS nadaum_read ON nadaum_grants;
CREATE POLICY nadaum_read ON nadaum_grants FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin());
-- 쓰기 정책은 일부러 두지 않는다. 아래 함수(SECURITY DEFINER)로만 들어간다

-- ── 2. 지급 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION grant_nadaum(p_user uuid, p_amount int, p_reason text) RETURNS jsonb AS $$
DECLARE v_role text; v_lead boolean; v_gone timestamptz; v_id bigint; v_why text;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  v_why := btrim(COALESCE(p_reason, ''));
  IF v_why = '' THEN RAISE EXCEPTION '사유를 적어주세요'; END IF;
  IF p_amount IS NULL OR p_amount < 1 OR p_amount > 1000 THEN
    RAISE EXCEPTION '한 번에 1~1000N 까지 줄 수 있어요. 더 줄 일이 있으면 나눠서 주세요';
  END IF;

  SELECT COALESCE(role, 'youth'), COALESCE(can_lead, false), withdrawn_at
    INTO v_role, v_lead, v_gone FROM profiles WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 회원이 없어요'; END IF;
  IF v_gone IS NOT NULL THEN RAISE EXCEPTION '탈퇴한 회원이에요'; END IF;
  IF v_role <> 'youth' OR v_lead THEN RAISE EXCEPTION '청소년에게만 줄 수 있어요'; END IF;

  INSERT INTO nadaum_grants (user_id, amount, reason, granted_by)
  VALUES (p_user, p_amount, v_why, auth.uid()) RETURNING id INTO v_id;

  -- 받은 아이에게 알린다. 알림이 터져도 지급은 그대로 들어간다
  BEGIN
    PERFORM notify_push(p_user, '나다움 ' || p_amount || 'N을 받았어요 🎁', left(v_why, 60),
                        '/youthit-book/app.html?tab=my');
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'amount', p_amount);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION grant_nadaum(uuid, int, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION grant_nadaum(uuid, int, text) TO authenticated;

-- ── 2. 회수 ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION void_nadaum(p_grant_id bigint, p_reason text) RETURNS jsonb AS $$
DECLARE g nadaum_grants;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  IF btrim(COALESCE(p_reason, '')) = '' THEN RAISE EXCEPTION '회수 사유를 적어주세요'; END IF;
  SELECT * INTO g FROM nadaum_grants WHERE id = p_grant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 지급이 없어요'; END IF;
  IF g.voided_at IS NOT NULL THEN RAISE EXCEPTION '이미 회수한 건이에요'; END IF;
  UPDATE nadaum_grants
     SET voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason)
   WHERE id = p_grant_id;
  RETURN jsonb_build_object('ok', true, 'id', p_grant_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION void_nadaum(bigint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION void_nadaum(bigint, text) TO authenticated;

-- ── 3. 합계에 더한다 ───────────────────────────────────
CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int; v_rev int; v_meet int; v_manual int;
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
         AND m.parent_id IS NULL      -- 답글에는 나다움이 없다 (2026-10-27)
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

  -- 운영진이 손으로 준 나다움 (회수한 것은 뺀다)
  SELECT COALESCE(sum(amount), 0) INTO v_manual FROM nadaum_grants WHERE user_id = v_u AND voided_at IS NULL;

  v_points := v_cert + v_cmt + v_bonus + v_rev + v_meet + v_manual;

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
    'from_manual',  v_manual,
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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_name = 'nadaum_grants')                                 AS 표_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname IN ('grant_nadaum', 'void_nadaum'))                                     AS 함수_2여야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_points' AND prosrc LIKE '%nadaum_grants%')                    AS 합계_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_points' AND prosrc LIKE '%parent_id IS NULL%')                AS 답글제외_그대로_1이어야;
