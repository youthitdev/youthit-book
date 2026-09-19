-- 한끗독서 마이그레이션 31
-- 책마다 하루 한 번 인증. 포인트는 하루에 한 번.
--
-- 마이그레이션 30 으로 한 루틴에서 세 권까지 읽게 해놓고, 정작 하루에
-- 한 권만 기록할 수 있었다. (루틴, 사람, 날짜)가 유일해야 했기 때문이다.
-- 병렬독서를 만들면서 만든 모순이다.
--
-- 그렇다고 하루에 몇 번이든 열면 격자가 한 사람 것으로 덮인다. 하루에
-- 다섯 장 올리는 아이 옆에서 한 장 올린 아이는 위축된다. 딱 필요한 만큼만
-- 연다 — 책마다 하루 한 번. 세 권을 읽었으면 세 장이고 그 이상은 없다.
--
-- 포인트는 그날 몇 권을 읽었든 하루치다. 안 그러면 세 권 읽은 날 30P 가 된다.

-- ── 1. 하루 한 번 → 책마다 하루 한 번 ──────────────────
DROP INDEX IF EXISTS certs_once_a_day_idx;

-- book_title 이 NULL 이면 유니크가 안 걸린다(NULL 끼리는 서로 다르다).
-- 옛 기록에 NULL 이 있으므로 빈 문자열로 접어서 건다
CREATE UNIQUE INDEX IF NOT EXISTS certs_once_a_day_per_book_idx
  ON certifications (routine_id, user_id, cert_date, COALESCE(btrim(book_title), ''));

-- ── 2. 포인트는 날짜로 센다 ────────────────────────────
CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int; v_rev int;
  v_per int; v_ppc int; v_cap int; v_pm int; v_ms int[]; v_pr int; v_pb int;
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap,
         points_per_milestone, bonus_milestones,
         points_per_review, points_per_bookreview
    INTO v_per, v_ppc, v_cap, v_pm, v_ms, v_pr, v_pb
    FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 250), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);
  v_pm  := COALESCE(v_pm, 10);
  v_ms  := COALESCE(v_ms, '{10,30,66,100,200}');
  v_pr  := COALESCE(v_pr, 30);
  v_pb  := COALESCE(v_pb, 30);

  -- 하루에 한 번이다. 같은 날 세 권을 읽어도 그날치 한 번.
  -- 루틴마다 points_per_cert 가 달라서 (루틴, 날짜)로 묶어 더한다
  SELECT COALESCE(sum(ppc), 0) INTO v_cert FROM (
    SELECT max(r.points_per_cert) AS ppc
      FROM certifications c JOIN routines r ON r.id = c.routine_id
     WHERE c.user_id = v_u
     GROUP BY c.routine_id, c.cert_date) t;

  -- 이정표도 날짜로 센다. 화면이 이미 "누적 인증 N일" 이라고 말하고 있다
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

  v_points := v_cert + v_cmt + v_bonus + v_rev;

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

-- ── 3. 공개 집계도 "일" 로 ─────────────────────────────
-- 화면이 「쌓인 독서 N일」이라고 말하는데 줄 수를 세고 있었다.
-- 책마다 하루 한 번이 되면 그 차이가 실제로 벌어지므로 지금 맞춘다
CREATE OR REPLACE FUNCTION dokseo_reading_stats() RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'pages_read', COALESCE((
      SELECT sum(mx) FROM (
        SELECT max(page_end) AS mx FROM certifications
         WHERE page_end IS NOT NULL
         GROUP BY user_id, routine_id, book_title) t), 0),
    'books_titles',   COALESCE((SELECT count(DISTINCT book_title) FROM certifications
                                 WHERE book_title IS NOT NULL AND book_title <> ''), 0),
    -- 사람×날짜. 한 사람이 하루에 세 권을 읽어도 하루다
    'cert_total',     COALESCE((SELECT count(*) FROM (
                                 SELECT DISTINCT user_id, cert_date FROM certifications) t), 0),
    'students_total', COALESCE((SELECT count(DISTINCT user_id) FROM certifications), 0)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION dokseo_reading_stats() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ↓ 바뀐 포인트. 줄 나와야 성공이다
SELECT u.email,
       dokseo_points(u.id) ->> 'points'     AS 총포인트,
       dokseo_points(u.id) ->> 'from_cert'  AS 인증포인트,
       dokseo_points(u.id) ->> 'cert_count' AS 인증일수,
       (SELECT count(*) FROM certifications c WHERE c.user_id = u.id) AS 인증줄수
  FROM auth.users u JOIN profiles p ON p.id = u.id
 WHERE p.role = 'youth' ORDER BY 2 DESC;
