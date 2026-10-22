-- 한끗독서 마이그레이션 145
-- 「매일 한끗」 — 일반 루틴이 없는 날에도 매일 한 장 인증할 수 있는 상시 루틴 (2026-10-22 사용자)
--
-- 【정해진 것】 · 하루 인증 1N · 다른 루틴과 함께 참여 가능 · 아이가 직접 「참여하기」를 눌러 들어온다
--   · 인증과 사진은 **나만** 본다. 다른 참여자에게는 닉네임·지금 읽는 책 표지·연속 인증일·「오늘 올렸어요」 표시만 보인다
--   · 이름은 「매일 한끗」. 기간이 없다(end_date 가 비어 있다) — 자동으로 끝나지 않는다.
--
-- 【무엇을】
--   1. routines.ongoing 칸을 만들고, 「매일 한끗」 루틴 한 개를 만든다 (이미 상시 루틴이 있으면 만들지 않는다).
--   2. visible_routine_ids() 에서 상시 루틴을 뺀다 → 다른 사람의 인증·댓글·참여자는 RLS 가 막는다. 내 인증은 그대로 보인다.
--   3. 참여 검사(check_participant_insert): 상시 루틴은 참여 각오·책 제목 없이 바로 들어온다. 나이(만 14세)는 그대로 막는다.
--   4. 인증 알림(on_cert_to_lead): 상시 루틴의 인증은 누구에게도 알리지 않는다.
--   5. routine_members: 상시 루틴은 빼고, 대신 ongoing_board(루틴) 를 새로 만든다 — 최근에 올린 순서로 닉네임·책 표지·연속일·오늘 여부.
--   6. 통계(admin_stats): 상시 루틴은 루틴 수·참여·완주에서 뺀다 (완주·후기·종료가 없다).
--
-- 【그대로인 것】 나다움·교환권 계산 (하루 한 번, 루틴마다 정해진 값 — 상시 루틴은 1N). 책을 받는 루틴으로는 앱 화면에서 고르지 못하게 막는다.
-- 【알아 둘 것】 이정표 보너스(10·30·66·100·200일)는 모든 루틴의 인증한 날을 합쳐 세므로 상시 루틴 인증도 한 날로 센다.
--
-- ⚠️ 23·131·139·141·140·142·137 뒤에 돌린다. 여러 번 돌려도 된다. 돌린 뒤 143(Slack 리포트)을 다시 돌려야 리포트에서도 빠진다.

ALTER TABLE routines ADD COLUMN IF NOT EXISTS ongoing boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN routines.ongoing IS '상시 루틴(매일 한끗). 기간이 없고 나만 보는 기록이며, 완주·후기·종료가 없다';

-- ── 1. 「매일 한끗」 만들기 ─────────────────────────────
INSERT INTO routines (title, emoji, description, cert_guide, start_date, end_date, max_people,
                      status, kind, camera_only, points_per_cert, ongoing)
SELECT '매일 한끗', '🌱',
       '루틴이 없는 날에도 매일 한 장. 읽은 책 한 줄만 남기면 오늘 몫은 끝이에요. 나다움 1N이 쌓이고, 내 기록은 나만 봐요.',
       '지금 읽고 있는 책과 그 자리를 한 장 찍어 주세요. 읽은 쪽만 적으면 돼요.',
       (now() AT TIME ZONE 'Asia/Seoul')::date, NULL, 9999,
       'active', 'book', true, 1, true
 WHERE NOT EXISTS (SELECT 1 FROM routines WHERE ongoing);

-- ── 2. 남의 인증이 안 보이게 ────────────────────────────
-- 상시 루틴의 참여는 「볼 수 있는 루틴」으로 치지 않는다. (끗짱이 맡은 루틴은 그대로 — 상시 루틴에는 끗짱이 없다)
CREATE OR REPLACE FUNCTION visible_routine_ids()
RETURNS SETOF bigint AS $$
  SELECT r.id FROM routines r WHERE r.led_by = auth.uid()
  UNION
  SELECT p.routine_id FROM routine_participants p
    JOIN routines r ON r.id = p.routine_id
   WHERE p.user_id = auth.uid() AND p.status = 'approved' AND NOT r.ongoing;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ── 3. 참여 검사 ───────────────────────────────────────
CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text; v_age int; v_kind text; v_start date; v_ong boolean;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  SELECT age_years(pp.birth_date) INTO v_age
    FROM profiles_private pp WHERE pp.id = NEW.user_id;

  -- 생년월일이 없는 사람(예전 가입자)은 나이로 막지 않는다
  IF v_age IS NOT NULL AND v_age < 14 THEN
    RAISE EXCEPTION '한끗독서는 만 14세부터 함께할 수 있어요';
  END IF;

  -- 청소년 확인은 여기서 묻지 않는다. 책을 받을 때 check_purchase_verified 가 본다

  NEW.status := 'approved';

  -- 상시 루틴(매일 한끗)은 신청서가 없다. 참여 각오·책 제목 없이 바로 들어온다 (나이는 위에서 이미 봤다)
  SELECT ongoing INTO v_ong FROM routines WHERE id = NEW.routine_id;
  IF COALESCE(v_ong, false) THEN
    NEW.note := COALESCE(NULLIF(btrim(NEW.note), ''), '매일 한끗');
    NEW.book_title := NULL;
    NEW.book_photo_url := NULL;
    RETURN NEW;
  END IF;

  SELECT max_people, status, COALESCE(kind, 'book'), start_date
    INTO v_max, v_status, v_kind, v_start
    FROM routines WHERE id = NEW.routine_id;

  IF v_kind = 'shared' THEN
    -- 책이 없는 루틴이다. 들고 있지도 않은 걸 내놓으라고 하지 않는다
    NEW.book_title := NULL;
    NEW.book_photo_url := NULL;
  ELSIF v_kind = 'one_book' THEN
    -- 끗짱이 정한 한 권. 제목은 있어야 하고, 표지는 있으면 쓴다
    IF COALESCE(btrim(NEW.book_title), '') = '' THEN
      RAISE EXCEPTION '끗짱이 아직 읽을 책을 정하지 않았어요';
    END IF;
  ELSE
    -- 책 사진은 받지 않아도 된다 (선택). 제목만 있으면 된다 — 표지는 검색에서 고른 공식 표지를 쓴다
    IF COALESCE(btrim(NEW.book_title), '') = '' THEN
      RAISE EXCEPTION '읽을 책 제목을 적어주세요';
    END IF;
  END IF;

  IF COALESCE(btrim(NEW.note), '') = '' THEN
    RAISE EXCEPTION '참여 각오를 적어주세요';
  END IF;

  IF v_status = 'done' THEN
    RAISE EXCEPTION '이미 끝난 루틴이에요';
  END IF;
  -- 진행 중이어도 시작하는 날(1일차)까지는 받는다. 다음 날부터 막는다
  IF v_status = 'active' AND v_start IS DISTINCT FROM (now() AT TIME ZONE 'Asia/Seoul')::date THEN
    RAISE EXCEPTION '모집이 끝난 루틴이에요';
  END IF;
  SELECT count(*) INTO v_now FROM routine_participants
   WHERE routine_id = NEW.routine_id AND status = 'approved';
  IF v_max IS NOT NULL AND v_now >= v_max THEN
    RAISE EXCEPTION '정원이 찼어요';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. 인증 알림 ───────────────────────────────────────
CREATE OR REPLACE FUNCTION on_cert_to_lead() RETURNS trigger AS $$
DECLARE v_ong boolean; v_title text; v_lead uuid; v_who text; v_book text; v_body text; u uuid;
BEGIN
  SELECT r.title, r.led_by, r.ongoing INTO v_title, v_lead, v_ong FROM routines r WHERE r.id = NEW.routine_id;
  -- 상시 루틴(매일 한끗)의 인증은 나만 보는 기록이다. 다른 사람에게도, 운영진에게도 알리지 않는다
  IF COALESCE(v_ong, false) THEN RETURN NEW; END IF;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  -- 누가 했는지는 제목에, 책은 내용에 (알림을 누르면 그 인증이 열린다)
  v_book := COALESCE('『' || NULLIF(left(btrim(NEW.book_title), 40), '') || '』', '');

  -- 끗짱 + 승인된 참여자 + 운영진. 올린 사람은 뺀다. UNION 이 겹침도 걷어 준다
  FOR u IN
    SELECT x FROM (
      SELECT v_lead AS x
      UNION
      SELECT rp.user_id FROM routine_participants rp
       WHERE rp.routine_id = NEW.routine_id AND rp.status = 'approved'
      UNION
      SELECT a FROM public.admin_user_ids() a
    ) t
    WHERE x IS NOT NULL AND x <> NEW.user_id
  LOOP
    -- 운영진에게만 루틴 이름을 붙인다. 여러 루틴의 인증이 한꺼번에 오기 때문이다
    IF EXISTS (SELECT 1 FROM public.admin_user_ids() a WHERE a = u) AND u IS DISTINCT FROM v_lead
       AND NOT EXISTS (SELECT 1 FROM routine_participants rp
                        WHERE rp.routine_id = NEW.routine_id AND rp.user_id = u AND rp.status = 'approved') THEN
      v_body := COALESCE(v_title, '루틴') || CASE WHEN v_book <> '' THEN ' · ' || v_book ELSE '' END;
    ELSE
      v_body := v_book;
    END IF;
    PERFORM notify_push(u, COALESCE(v_who, '친구') || '님이 인증했어요 📖', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id || '&cert=' || NEW.id, 'friends');
  END LOOP;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

-- ── 5. 친구들 · 상시 루틴 보드 ──────────────────────────
-- 돌려주는 칸이 같아도 정의가 바뀌므로 먼저 지우고 다시 만든다
DROP FUNCTION IF EXISTS routine_members(bigint);
CREATE FUNCTION routine_members(p_routine bigint)
RETURNS TABLE (nick text, books jsonb, intro_id bigint, intro_body text, intro_photo text) AS $$
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), '친구'),
         COALESCE((SELECT jsonb_agg(jsonb_build_object('t', b.title,
                                      'c', COALESCE(NULLIF(btrim(bc.cover_url), ''), NULLIF(btrim(COALESCE(b.found_cover_url, '')), '')))
                                    ORDER BY b.created_at)
                     FROM routine_books b
                     LEFT JOIN book_covers bc ON bc.k = book_key(b.title)
                    WHERE b.routine_id = rp.routine_id AND b.user_id = rp.user_id), '[]'::jsonb),
         ri.id, ri.body, ri.photo_url
    FROM routine_participants rp
    JOIN routines r ON r.id = rp.routine_id
    JOIN profiles p ON p.id = rp.user_id
    LEFT JOIN routine_intros ri ON ri.routine_id = rp.routine_id AND ri.user_id = rp.user_id AND NOT ri.hidden
   WHERE rp.routine_id = p_routine
     AND rp.status = 'approved'
     AND r.status IN ('recruit', 'active')
     AND NOT COALESCE(r.ongoing, false)   -- 상시 루틴은 친구들 목록이 없다 (아래 ongoing_board 가 따로 있다)
     AND p.withdrawn_at IS NULL
     AND COALESCE(p.role, 'youth') = 'youth'
     AND NOT COALESCE(p.can_lead, false)
     AND ( auth.uid() IS NULL
           OR is_admin()
           OR EXISTS (SELECT 1 FROM profiles me
                       WHERE me.id = auth.uid() AND me.withdrawn_at IS NULL
                         AND (me.verify_status = 'approved' OR me.can_lead)) )
   ORDER BY rp.joined_at
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION routine_members(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION routine_members(bigint) TO authenticated;

-- 상시 루틴의 보드: 참여해서 한 번이라도 인증한 청소년을 **최근에 올린 순서**로. 닉네임·지금 읽는 책 표지·연속 인증일·오늘 올렸는지만 준다.
-- 인증 사진·글·쪽수·책 제목은 내보내지 않는다. 참여한 사람(과 운영진)만 부를 수 있다.
CREATE OR REPLACE FUNCTION ongoing_board(p_routine bigint)
RETURNS TABLE (nick text, cover text, streak int, last_day date, today boolean) AS $$
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
         EXISTS (SELECT 1 FROM d d3 WHERE d3.user_id = lastc.user_id AND d3.cert_date = v_today)
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

-- ── 6. 통계에서 빼기 ───────────────────────────────────
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
     WHERE ro.status IN ('recruit', 'active', 'done') AND NOT COALESCE(ro.ongoing, false)
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
      'recruit', (SELECT count(*) FROM routines WHERE status = 'recruit' AND NOT ongoing),
      'active',  (SELECT count(*) FROM routines WHERE status = 'active' AND NOT ongoing),
      'done',    (SELECT count(*) FROM routines WHERE status = 'done' AND NOT canceled AND NOT ongoing),
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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 상시 루틴 1 · 보드 함수 1 · 참여 검사가 새 판 1 · 알림 함수가 새 판 1 · 통계가 새 판 1
SELECT (SELECT count(*) FROM routines WHERE ongoing)                                                                 AS 상시루틴_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'ongoing_board')                                               AS 보드_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'check_participant_insert' AND prosrc LIKE '%매일 한끗%')        AS 참여검사_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'on_cert_to_lead' AND prosrc LIKE '%v_ong%')                    AS 알림_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'admin_stats' AND prosrc LIKE '%NOT COALESCE(ro.ongoing%')       AS 통계_1이어야;
