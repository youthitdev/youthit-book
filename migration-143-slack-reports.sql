-- 한끗독서 마이그레이션 143
-- 운영진이 아침마다 받는 「일일 리포트」와 일요일 저녁의 「주간 리포트」를 Slack 으로 보낸다 (2026-10-21 사용자)
--
-- 【무엇을 담나 — 숫자가 아니라 사람으로】 「어제 12건」보다 「민지가 사흘째 비었어요」가 아침에 필요한 정보다.
--   일일(매일 오전 9시): 어제 인증(지난주 같은 요일과 비교) · 루틴별 어제 인증 · 사흘 이상 인증이 없는 청소년 ·
--                       댓글 없이 지나간 어제 인증 · 처리할 것(확인·신청·열어달라는 루틴) · 오늘 공유회
--   주간(일요일 저녁 7시): 이번 주 인증(지난주 비교) · 루틴별 인증률·남은 날 · 많이 읽힌 책 ·
--                         교환권이 있는데 아직 안 쓴 청소년 · 정산 기다리는 책방 · 한 달 안에 끝나는 루틴
--
-- 【개인정보】 Slack 에는 **닉네임**만 쓴다 (이름·연락처·학교는 넣지 않는다). 연락이 필요하면 관리자 화면에서 찾는다.
--
-- 【Slack 이 없어도 볼 수 있다】 SQL Editor 에서 아래 둘을 실행하면 리포트 글이 그대로 나온다 — 보내지 않는다.
--       SELECT build_daily_report();      SELECT build_weekly_report();
--
-- 【Slack 으로 보내려면 — 운영진이 직접 한다】 ① Slack 앱에서 「Incoming Webhook」을 만들어 주소(https://hooks.slack.com/…)를 복사한다.
--   ② SQL Editor 에서 한 번만:  SELECT vault.create_secret('복사한_주소', 'slack_webhook');
--   (주소는 금고에 들어가고, 이 코드나 화면 어디에도 남지 않는다.) 주소를 바꿀 때는 먼저 지우고 다시 넣는다.
--   ③ 시험 발송:  SELECT send_slack_report('daily');   → 'sent' 이 나오고 Slack 에 글이 오면 된다.
--
-- 【항목 하나가 틀려도 리포트는 나간다】 각 항목을 따로 감싸 두었다. 항목을 못 만들면 그 줄에 「못 만들었어요」만 적힌다.
--
-- ⚠️ 40(pg_cron)·44(pg_net)·71(dokseo_points_all)·78(admin_user_ids)·133·135 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION report_nick(p_user uuid) RETURNS text AS $$
  SELECT COALESCE(NULLIF(btrim(nick), ''), '이름 없음') FROM profiles WHERE id = p_user
$$ LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public;

-- ── 일일 ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION build_daily_report() RETURNS text AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_y     date := (now() AT TIME ZONE 'Asia/Seoul')::date - 1;
  v_dow   text := (ARRAY['일','월','화','수','목','금','토'])[extract(dow FROM (now() AT TIME ZONE 'Asia/Seoul')::date - 1)::int + 1];
  v_out   text;
  v_a int; v_b int; v_x text; r record; n int;
BEGIN
  v_out := '*📋 한끗독서 일일 리포트* · ' || to_char(v_y, 'MM/DD') || '(' || v_dow || ') 기준' || E'\n';

  -- 1. 어제 인증
  BEGIN
    -- 끗짱이 올린 인증은 세지 않는다 (참여 인원도 청소년만 센다 — 「5/4명」처럼 어긋나지 않게)
    SELECT count(*) INTO v_a FROM certifications c JOIN profiles pp ON pp.id = c.user_id
     WHERE c.cert_date = v_y AND NOT COALESCE(pp.can_lead, false);
    SELECT count(*) INTO v_b FROM certifications c JOIN profiles pp ON pp.id = c.user_id
     WHERE c.cert_date = v_y - 7 AND NOT COALESCE(pp.can_lead, false);
    v_out := v_out || E'\n*어제 청소년 인증* ' || v_a || '건 (지난주 같은 요일 ' || v_b || '건)' || E'\n';
    v_x := '';
    FOR r IN
      SELECT ro.title,
             (SELECT count(DISTINCT c.user_id) FROM certifications c JOIN profiles pp ON pp.id = c.user_id
               WHERE c.routine_id = ro.id AND c.cert_date = v_y AND NOT COALESCE(pp.can_lead, false)) AS a,
             (SELECT count(*) FROM routine_participants rp JOIN profiles pp ON pp.id = rp.user_id
               WHERE rp.routine_id = ro.id AND rp.status = 'approved' AND NOT COALESCE(pp.can_lead, false)) AS p
        FROM routines ro
       WHERE ro.status = 'active' AND NOT COALESCE(ro.canceled, false)
       ORDER BY ro.start_date
    LOOP
      v_x := v_x || '• ' || r.title || ' — ' || r.a || '/' || r.p || '명' || E'\n';
    END LOOP;
    v_out := v_out || COALESCE(NULLIF(v_x, ''), '• 진행 중인 루틴이 없어요' || E'\n');
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'• (어제 인증을 못 만들었어요)\n';
  END;

  -- 2. 사흘 이상 인증이 없는 청소년 (진행 중 루틴의 참여자)
  BEGIN
    v_x := ''; n := 0;
    FOR r IN
      SELECT report_nick(rp.user_id) AS nick, ro.title,
             lc.d AS last_d,
             (v_y - COALESCE(lc.d, GREATEST(ro.start_date, (rp.joined_at AT TIME ZONE 'Asia/Seoul')::date) - 1)) AS gap
        FROM routine_participants rp
        JOIN routines ro ON ro.id = rp.routine_id AND ro.status = 'active' AND NOT COALESCE(ro.canceled, false)
        JOIN profiles pp ON pp.id = rp.user_id
        LEFT JOIN LATERAL (SELECT max(c.cert_date) AS d FROM certifications c
                            WHERE c.routine_id = rp.routine_id AND c.user_id = rp.user_id) lc ON true
       WHERE rp.status = 'approved' AND NOT COALESCE(pp.can_lead, false) AND pp.withdrawn_at IS NULL
         AND ro.start_date <= v_y
         AND (v_y - COALESCE(lc.d, GREATEST(ro.start_date, (rp.joined_at AT TIME ZONE 'Asia/Seoul')::date) - 1)) >= 3
       ORDER BY 4 DESC, 1
    LOOP
      n := n + 1;
      IF n <= 15 THEN
        v_x := v_x || '• ' || r.nick || ' — ' || r.title || ' · '
               || CASE WHEN r.last_d IS NULL THEN '아직 인증 없음' ELSE '마지막 ' || to_char(r.last_d, 'MM/DD') END
               || ' (' || r.gap || '일째)' || E'\n';
      END IF;
    END LOOP;
    v_out := v_out || E'\n*🔔 사흘 이상 인증이 없는 청소년* ' || n || '명' || E'\n'
             || CASE WHEN n = 0 THEN E'• 없어요 👍\n' ELSE v_x || CASE WHEN n > 15 THEN '• … 외 ' || (n - 15) || E'명\n' ELSE '' END END;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*🔔 사흘 이상 인증이 없는 청소년*\n• (못 만들었어요)\n';
  END;

  -- 3. 댓글 없이 지나간 어제 인증 (끗짱이 못 챙긴 것)
  BEGIN
    v_x := ''; n := 0;
    FOR r IN
      SELECT ro.title, count(*) AS k
        FROM certifications c
        JOIN routines ro ON ro.id = c.routine_id
        JOIN profiles pp ON pp.id = c.user_id AND NOT COALESCE(pp.can_lead, false)
       WHERE c.cert_date = v_y AND ro.status IN ('active', 'done')
         AND NOT EXISTS (SELECT 1 FROM cert_comments m WHERE m.cert_id = c.id)
       GROUP BY ro.title ORDER BY 2 DESC, 1
    LOOP
      n := n + r.k; v_x := v_x || '• ' || r.title || ' ' || r.k || E'건\n';
    END LOOP;
    v_out := v_out || E'\n*💬 댓글 없이 지나간 어제 인증* ' || n || '건' || E'\n' || CASE WHEN n = 0 THEN E'• 모두 반응이 있었어요 👍\n' ELSE v_x END;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*💬 댓글 없이 지나간 어제 인증*\n• (못 만들었어요)\n';
  END;

  -- 4. 처리할 것
  BEGIN
    v_out := v_out || E'\n*🛎️ 처리할 것*' || E'\n'
      || '• 청소년 확인 대기 ' || (SELECT count(*) FROM profiles WHERE verify_status = 'pending' AND withdrawn_at IS NULL) || E'건\n'
      || '• 끗짱 신청 대기 ' || (SELECT count(*) FROM kkut_applications WHERE status = 'pending') || E'건\n'
      || '• 열어달라는 루틴 ' || (SELECT count(*) FROM routines WHERE status = 'pending') || E'건\n';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*🛎️ 처리할 것*\n• (못 만들었어요)\n';
  END;

  -- 5. 오늘 공유회
  BEGIN
    v_x := '';
    FOR r IN
      SELECT title, meetup_at, meetup_place FROM routines
       WHERE meetup_required AND meetup_at IS NOT NULL
         AND (meetup_at AT TIME ZONE 'Asia/Seoul')::date = v_today
       ORDER BY meetup_at
    LOOP
      v_x := v_x || '• ' || r.title || ' · ' || to_char(r.meetup_at AT TIME ZONE 'Asia/Seoul', 'HH24:MI')
             || COALESCE(' · ' || NULLIF(btrim(r.meetup_place), ''), '') || E'\n';
    END LOOP;
    IF v_x <> '' THEN v_out := v_out || E'\n*🤝 오늘 공유회*\n' || v_x; END IF;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN v_out;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- ── 주간 ────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION build_weekly_report() RETURNS text AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_from  date := (now() AT TIME ZONE 'Asia/Seoul')::date - 6;     -- 오늘을 포함한 7일
  v_out   text;
  v_a int; v_b int; v_u int; v_x text; r record; n int;
BEGIN
  v_out := '*📊 한끗독서 주간 리포트* · ' || to_char(v_from, 'MM/DD') || ' ~ ' || to_char(v_today, 'MM/DD') || E'\n';

  -- 1. 이번 주 인증
  BEGIN
    SELECT count(*), count(DISTINCT c.user_id) INTO v_a, v_u FROM certifications c JOIN profiles pp ON pp.id = c.user_id
     WHERE c.cert_date BETWEEN v_from AND v_today AND NOT COALESCE(pp.can_lead, false);
    SELECT count(*) INTO v_b FROM certifications c JOIN profiles pp ON pp.id = c.user_id
     WHERE c.cert_date BETWEEN v_from - 7 AND v_today - 7 AND NOT COALESCE(pp.can_lead, false);
    v_out := v_out || E'\n*이번 주 청소년 인증* ' || v_a || '건 (지난주 ' || v_b || '건) · 인증한 사람 ' || v_u || E'명\n';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*이번 주 인증*\n• (못 만들었어요)\n';
  END;

  -- 2. 루틴별 인증률 (이번 주, 청소년 참여자 × 그 주의 루틴 일수) · 남은 날
  BEGIN
    v_x := '';
    FOR r IN
      SELECT ro.title, ro.end_date,
             (SELECT count(*) FROM routine_participants rp JOIN profiles pp ON pp.id = rp.user_id
               WHERE rp.routine_id = ro.id AND rp.status = 'approved' AND NOT COALESCE(pp.can_lead, false)) AS p,
             (SELECT count(DISTINCT (c.user_id, c.cert_date)) FROM certifications c JOIN profiles pp ON pp.id = c.user_id
               WHERE c.routine_id = ro.id AND c.cert_date BETWEEN v_from AND v_today AND NOT COALESCE(pp.can_lead, false)) AS done,
             (LEAST(v_today, ro.end_date) - GREATEST(v_from, ro.start_date) + 1) AS d
        FROM routines ro
       WHERE ro.status = 'active' AND NOT COALESCE(ro.canceled, false)
       ORDER BY ro.start_date
    LOOP
      v_x := v_x || '• ' || r.title || ' — '
             || CASE WHEN r.p * GREATEST(r.d, 0) > 0 THEN round(r.done * 100.0 / (r.p * r.d)) || '%' ELSE '—' END
             || ' · 참여 ' || r.p || '명 · 종료까지 ' || GREATEST(r.end_date - v_today, 0) || E'일\n';
    END LOOP;
    v_out := v_out || E'\n*루틴별 이번 주 인증률*\n' || COALESCE(NULLIF(v_x, ''), E'• 진행 중인 루틴이 없어요\n');
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*루틴별 이번 주 인증률*\n• (못 만들었어요)\n';
  END;

  -- 3. 이번 주 많이 읽힌 책 (인증에 적힌 책, 읽은 사람 수)
  BEGIN
    v_x := '';
    FOR r IN
      SELECT book_title, count(DISTINCT user_id) AS k FROM certifications
       WHERE cert_date BETWEEN v_from AND v_today AND NULLIF(btrim(COALESCE(book_title, '')), '') IS NOT NULL
       GROUP BY book_title ORDER BY 2 DESC, 1 LIMIT 5
    LOOP
      v_x := v_x || '• ' || r.book_title || ' — ' || r.k || E'명\n';
    END LOOP;
    v_out := v_out || E'\n*📚 이번 주 많이 읽힌 책*\n' || COALESCE(NULLIF(v_x, ''), E'• 아직 없어요\n');
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*📚 이번 주 많이 읽힌 책*\n• (못 만들었어요)\n';
  END;

  -- 4. 교환권이 있는데 아직 안 쓴 청소년
  BEGIN
    SELECT count(*) INTO n FROM dokseo_points_all() a JOIN profiles p ON p.id = a.user_id
     WHERE p.withdrawn_at IS NULL AND a.remain > 0;
    v_out := v_out || E'\n*🎫 교환권이 있는데 아직 안 쓴 청소년* ' || n || E'명\n';
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*🎫 교환권이 있는데 아직 안 쓴 청소년*\n• (못 만들었어요)\n';
  END;

  -- 5. 정산을 기다리는 책방
  BEGIN
    v_x := ''; n := 0;
    FOR r IN
      SELECT COALESCE(b.name, '책방 미정') AS name, count(*) AS k
        FROM book_purchases bp LEFT JOIN bookstores b ON b.id = bp.bookstore_id
       WHERE bp.status = 'pending' GROUP BY 1 ORDER BY 2 DESC, 1
    LOOP
      n := n + r.k; v_x := v_x || '• ' || r.name || ' ' || r.k || E'건\n';
    END LOOP;
    v_out := v_out || E'\n*💰 정산 대기* ' || n || '건' || E'\n' || CASE WHEN n = 0 THEN E'• 없어요 👍\n' ELSE v_x END;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*💰 정산 대기*\n• (못 만들었어요)\n';
  END;

  -- 6. 한 달 안에 끝나는 루틴
  BEGIN
    v_x := '';
    FOR r IN
      SELECT title, end_date FROM routines
       WHERE status IN ('active', 'recruit') AND NOT COALESCE(canceled, false)
         AND end_date BETWEEN v_today AND v_today + 30
       ORDER BY end_date
    LOOP
      v_x := v_x || '• ' || r.title || ' — ' || to_char(r.end_date, 'MM/DD') || ' 종료 (' || (r.end_date - v_today) || E'일 남음)\n';
    END LOOP;
    v_out := v_out || E'\n*🏁 한 달 안에 끝나는 루틴*\n' || COALESCE(NULLIF(v_x, ''), E'• 없어요\n');
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*🏁 한 달 안에 끝나는 루틴*\n• (못 만들었어요)\n';
  END;

  RETURN v_out;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public;

-- ── Slack 으로 보내기 ───────────────────────────────────
-- 주소가 금고에 없으면 아무것도 하지 않는다 (글만 만들고 끝). 보낸 결과 문구를 돌려준다
CREATE OR REPLACE FUNCTION send_slack_report(p_kind text) RETURNS text AS $$
DECLARE v_url text; v_txt text;
BEGIN
  SELECT decrypted_secret INTO v_url FROM vault.decrypted_secrets WHERE name = 'slack_webhook';
  IF v_url IS NULL OR btrim(v_url) = '' THEN RETURN 'no webhook'; END IF;
  v_txt := CASE p_kind WHEN 'weekly' THEN build_weekly_report() ELSE build_daily_report() END;
  PERFORM net.http_post(url := v_url,
                        headers := jsonb_build_object('Content-Type', 'application/json'),
                        body := jsonb_build_object('text', v_txt));
  RETURN 'sent';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

REVOKE EXECUTE ON FUNCTION report_nick(uuid)          FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION build_daily_report()       FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION build_weekly_report()      FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION send_slack_report(text)    FROM PUBLIC, anon, authenticated;

-- ── 시간표 (cron 은 UTC) ────────────────────────────────
-- 매일 오전 9시(한국) = 0시(UTC) · 일요일 저녁 7시(한국) = 10시(UTC)
SELECT cron.schedule('dokseo-slack-daily',  '0 0 * * *',  $$SELECT send_slack_report('daily')$$);
SELECT cron.schedule('dokseo-slack-weekly', '0 10 * * 0', $$SELECT send_slack_report('weekly')$$);

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 함수 4 · 시간표 2 · 금고에 주소 0(아직 안 넣었으면) 또는 1(넣었으면). 아래 두 줄로 글을 미리 볼 수 있다
SELECT (SELECT count(*) FROM pg_proc WHERE proname IN ('report_nick', 'build_daily_report', 'build_weekly_report', 'send_slack_report')) AS 함수_4여야,
       (SELECT count(*) FROM cron.job WHERE jobname IN ('dokseo-slack-daily', 'dokseo-slack-weekly'))                                     AS 시간표_2여야,
       (SELECT count(*) FROM vault.decrypted_secrets WHERE name = 'slack_webhook')                                                      AS 슬랙_주소_있으면_1;
-- 글 미리보기 (지금은 거의 빈 종이일 수 있다):
--   SELECT build_daily_report();
--   SELECT build_weekly_report();
