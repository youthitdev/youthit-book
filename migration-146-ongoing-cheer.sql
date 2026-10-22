-- 한끗독서 마이그레이션 146
-- 「매일 한끗」의 응원해요 ♥ (2026-10-22 사용자)
--
-- 【정해진 것】 · 하루에 한 사람에게 한 번 (내게는 못 누른다) · 푸시 알림 없음 · 나다움 없음 · 누가 눌렀는지는 안 보이고 개수만 보인다
--   · 보드의 친구 표지를 누르면 크게 열리고 거기서 「응원해요 ♥」를 누른다 · 내 홈 카드에는 오늘·어제 받은 응원 수가 한 줄 나온다
--
-- 【무엇을】
--   1. ongoing_cheers 표: 루틴·보낸 사람·받은 사람·날짜. (루틴, 보낸 사람, 받은 사람, 날짜)가 하나뿐이라 같은 날 두 번은 안 들어간다.
--      표는 앱에서 직접 읽거나 쓰지 못한다 — 아래 함수로만 한다.
--   2. ongoing_cheer(루틴, 표지): 응원한다. 상시 루틴에 참여한 사람만, 하루에 20명까지. 받는 사람은 닉네임이 아니라 「표지」(보드가 주는 해시)로 가린다 — 다른 아이의 계정 번호를 내보내지 않으려는 것이다.
--   3. ongoing_my_cheers(루틴): 내가 오늘·어제 받은 응원 수.
--   4. ongoing_board: 칸이 늘었다(표지·오늘 받은 수·내가 이미 응원했는지·나인지). 칸이 바뀌어서 먼저 지우고 다시 만든다.
--
-- ⚠️ 145 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS ongoing_cheers (
  routine_id bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  from_user  uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  to_user    uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  day        date   NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Seoul')::date),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (routine_id, from_user, to_user, day)
);
ALTER TABLE ongoing_cheers ENABLE ROW LEVEL SECURITY;   -- 정책이 없으니 앱에서는 읽지도 쓰지도 못한다

CREATE OR REPLACE FUNCTION ongoing_cheer(p_routine bigint, p_tid text) RETURNS text AS $$
DECLARE v_me uuid := auth.uid(); v_to uuid; v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date; v_n int; v_ins int;
BEGIN
  IF v_me IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM routines WHERE id = p_routine AND ongoing) THEN RAISE EXCEPTION '응원할 수 없는 루틴이에요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM routine_participants WHERE routine_id = p_routine AND user_id = v_me AND status = 'approved') THEN
    RAISE EXCEPTION '참여한 사람만 응원할 수 있어요';
  END IF;
  SELECT rp.user_id INTO v_to FROM routine_participants rp
   WHERE rp.routine_id = p_routine AND rp.status = 'approved'
     AND md5('ongoing-cheer:' || p_routine::text || ':' || rp.user_id::text) = p_tid
   LIMIT 1;
  IF v_to IS NULL THEN RAISE EXCEPTION '찾을 수 없는 친구예요'; END IF;
  IF v_to = v_me THEN RAISE EXCEPTION '내 책은 응원할 수 없어요'; END IF;
  SELECT count(*) INTO v_n FROM ongoing_cheers WHERE from_user = v_me AND day = v_today;
  IF v_n >= 20 THEN RAISE EXCEPTION '오늘은 20명까지 응원할 수 있어요'; END IF;
  INSERT INTO ongoing_cheers (routine_id, from_user, to_user, day) VALUES (p_routine, v_me, v_to, v_today)
    ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_ins = ROW_COUNT;
  RETURN CASE WHEN v_ins > 0 THEN 'ok' ELSE 'already' END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION ongoing_cheer(bigint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION ongoing_cheer(bigint, text) TO authenticated;

CREATE OR REPLACE FUNCTION ongoing_my_cheers(p_routine bigint) RETURNS TABLE (today int, yesterday int) AS $$
DECLARE v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;
  RETURN QUERY SELECT count(*) FILTER (WHERE oc.day = v_today)::int, count(*) FILTER (WHERE oc.day = v_today - 1)::int
                 FROM ongoing_cheers oc WHERE oc.routine_id = p_routine AND oc.to_user = auth.uid() AND oc.day >= v_today - 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION ongoing_my_cheers(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION ongoing_my_cheers(bigint) TO authenticated;

-- ── 보드에 응원 칸 더하기 ───────────────────────────────
DROP FUNCTION IF EXISTS ongoing_board(bigint);
CREATE FUNCTION ongoing_board(p_routine bigint)
RETURNS TABLE (nick text, cover text, streak int, last_day date, today boolean, tid text, hearts int, mine boolean, me boolean) AS $$
DECLARE v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;
  IF NOT is_admin() AND NOT EXISTS (SELECT 1 FROM routine_participants rp
       WHERE rp.routine_id = p_routine AND rp.user_id = auth.uid() AND rp.status = 'approved') THEN
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM routines WHERE id = p_routine AND ongoing) THEN RETURN; END IF;

  RETURN QUERY
  WITH d AS (SELECT DISTINCT c.user_id, c.cert_date FROM certifications c WHERE c.routine_id = p_routine),
  g AS (SELECT d.user_id, d.cert_date,
               d.cert_date - (row_number() OVER (PARTITION BY d.user_id ORDER BY d.cert_date))::int AS grp FROM d),
  runs AS (SELECT g.user_id, count(*)::int AS n, max(g.cert_date) AS last_d FROM g GROUP BY g.user_id, g.grp),
  cur AS (   -- 지금 이어지는 연속일: 마지막 인증이 오늘이거나 어제인 묶음
    SELECT runs.user_id, runs.n, runs.last_d FROM runs WHERE runs.last_d >= v_today - 1),
  lastc AS (  -- 가장 최근 인증의 책
    SELECT DISTINCT ON (c.user_id) c.user_id, c.book_title, c.created_at
      FROM certifications c WHERE c.routine_id = p_routine ORDER BY c.user_id, c.created_at DESC)
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), '친구'),
         COALESCE(NULLIF(btrim(bc.cover_url), ''), NULLIF(btrim(COALESCE(rb.found_cover_url, '')), '')),
         COALESCE(cur.n, 0),
         (SELECT max(d2.cert_date) FROM d d2 WHERE d2.user_id = lastc.user_id),
         EXISTS (SELECT 1 FROM d d3 WHERE d3.user_id = lastc.user_id AND d3.cert_date = v_today),
         md5('ongoing-cheer:' || p_routine::text || ':' || lastc.user_id::text),
         (SELECT count(*)::int FROM ongoing_cheers oc WHERE oc.routine_id = p_routine AND oc.to_user = lastc.user_id AND oc.day = v_today),
         EXISTS (SELECT 1 FROM ongoing_cheers oc WHERE oc.routine_id = p_routine AND oc.to_user = lastc.user_id AND oc.from_user = auth.uid() AND oc.day = v_today),
         (lastc.user_id = auth.uid())
    FROM lastc
    JOIN profiles p ON p.id = lastc.user_id AND p.withdrawn_at IS NULL
    LEFT JOIN cur ON cur.user_id = lastc.user_id
    LEFT JOIN book_covers bc ON bc.k = book_key(lastc.book_title)
    LEFT JOIN LATERAL (SELECT r2.found_cover_url FROM routine_books r2
                        WHERE r2.user_id = lastc.user_id AND r2.title = lastc.book_title
                        ORDER BY r2.created_at DESC LIMIT 1) rb ON true
   WHERE COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
   ORDER BY lastc.created_at DESC
   LIMIT 60;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION ongoing_board(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION ongoing_board(bigint) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 표 1 · 응원 함수 1 · 받은 수 함수 1 · 보드가 새 판(칸 9개) 1
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_name = 'ongoing_cheers')                                                  AS 표_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'ongoing_cheer')                                                                       AS 응원함수_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'ongoing_my_cheers')                                                                   AS 받은수함수_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'ongoing_board' AND pg_get_function_result(oid) LIKE '%hearts%')                       AS 보드_1이어야;
