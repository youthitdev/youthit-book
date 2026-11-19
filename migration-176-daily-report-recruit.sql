-- 한끗독서 마이그레이션 176
-- 일일 리포트에 「모집 중인 모임」 신청 현황 (2026-11-19 사용자: 「모집 중 모임의 신청 현황도 보여지면 좋겠어」, 주간은 빼고)
--
-- 【하는 일】 일일 리포트(build_daily_report)의 「곧 시작하는 모집 중」 항목을 고친다.
--   · 전에는 시작이 7일 안인 모임만 보였다 → 이제 **모집 중인 모임 전부**, 시작일이 빠른 순으로 보인다 (최대 10개, 넘으면 「… 외 N개」).
--   · 한 줄: 「모임 — 시작 D-3 (11/22) · 신청 2/8명 ⚠️ · 승인 대기 1명」
--       신청 = 승인된 청소년 / 정원 (끗짱은 세지 않는다). 승인 대기는 있을 때만 붙는다.
--       ⚠️ = 시작이 7일 안(이미 지난 것 포함)인데 신청이 3명 미만.
--   · 닉네임 없이 숫자만. 모집 중인 모임이 없으면 항목이 통째로 빠진다.
--   · 주간 리포트(build_weekly_report)는 건드리지 않는다.
--
-- 【왜 함수 전체를 다시 쓰나】 143 의 함수는 163 에서 「루틴」→「모임」으로 바뀌어 DB 에 들어 있다.
--   143 만 다시 돌리면 문구가 도로 「루틴」이 된다. 그래서 163 과 같은 문구(모임)로 전체를 새로 만든다.
--   고친 곳은 3-3 항목 하나뿐이고 나머지는 143 과 같다. (143 파일은 건드리지 않았다 — 이 파일이 현재 정의다)
--
-- 시험: 아래 확인 줄이 리포트 글을 그대로 보여 준다 (Slack 으로 보내지 않는다).
-- 되돌리려면: 143 을 다시 돌린 뒤 163 을 다시 돌린다.
-- ⚠️ 143·147·163 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION build_daily_report() RETURNS text AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_y     date := (now() AT TIME ZONE 'Asia/Seoul')::date - 1;
  v_dow   text := (ARRAY['일','월','화','수','목','금','토'])[extract(dow FROM (now() AT TIME ZONE 'Asia/Seoul')::date - 1)::int + 1];
  v_out   text;
  v_a int; v_b int; v_x text; r record; n int; j jsonb;
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
       WHERE ro.status = 'active' AND NOT COALESCE(ro.canceled, false) AND NOT COALESCE(ro.ongoing, false)
       ORDER BY ro.start_date
    LOOP
      v_x := v_x || '• ' || r.title || ' — ' || r.a || '/' || r.p || '명' || E'\n';
    END LOOP;
    v_out := v_out || COALESCE(NULLIF(v_x, ''), '• 진행 중인 모임이 없어요' || E'\n');
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'• (어제 인증을 못 만들었어요)\n';
  END;

  -- 2. 사흘 이상 인증이 없는 청소년 (진행 중 모임의 참여자)
  BEGIN
    v_x := ''; n := 0;
    FOR r IN
      SELECT report_nick(rp.user_id) AS nick, ro.title,
             lc.d AS last_d,
             (v_y - COALESCE(lc.d, GREATEST(ro.start_date, (rp.joined_at AT TIME ZONE 'Asia/Seoul')::date) - 1)) AS gap
        FROM routine_participants rp
        JOIN routines ro ON ro.id = rp.routine_id AND ro.status = 'active' AND NOT COALESCE(ro.canceled, false) AND NOT COALESCE(ro.ongoing, false)
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

  -- 3-2. 어제 글이 안 올라온 「함께 읽는 글」 모임 — 글이 없으면 그날 아이들이 인증을 못 한다
  BEGIN
    v_x := ''; n := 0;
    FOR r IN
      SELECT ro.title, ro.led_by FROM routines ro
       WHERE ro.kind = 'shared' AND ro.status = 'active' AND NOT COALESCE(ro.canceled, false) AND NOT COALESCE(ro.ongoing, false)
         AND ro.start_date <= v_y AND (ro.end_date IS NULL OR ro.end_date >= v_y)
         AND NOT EXISTS (SELECT 1 FROM routine_posts po WHERE po.routine_id = ro.id AND po.day = v_y)
       ORDER BY ro.start_date
    LOOP
      n := n + 1; v_x := v_x || '• ' || r.title || ' — 끗짱 ' || report_nick(r.led_by) || E'\n';
    END LOOP;
    IF n > 0 THEN
      v_out := v_out || E'\n*✍️ 어제 글이 안 올라온 「함께 읽는 글」 모임* ' || n || E'개\n' || v_x;
    ELSIF EXISTS (SELECT 1 FROM routines WHERE kind = 'shared' AND status = 'active' AND NOT COALESCE(canceled, false) AND start_date <= v_y) THEN
      v_out := v_out || E'\n*✍️ 「함께 읽는 글」 모임* — 어제 글이 모두 올라왔어요 👍\n';
    END IF;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*✍️ 「함께 읽는 글」 모임*\n• (못 만들었어요)\n';
  END;

  -- 3-3. 모집 중인 모임 전부 — 신청 인원(승인된 청소년/정원)과 승인 대기. 시작이 7일 안인데 신청이 3명 미만이면 ⚠️
  --       (176: 전에는 시작이 7일 안인 것만 보였다). 주간 리포트에는 넣지 않는다
  BEGIN
    v_x := ''; n := 0;
    FOR r IN
      SELECT ro.title, ro.start_date, ro.max_people,
             (SELECT count(*) FROM routine_participants rp JOIN profiles pp ON pp.id = rp.user_id
               WHERE rp.routine_id = ro.id AND rp.status = 'approved' AND NOT COALESCE(pp.can_lead, false)) AS p,
             (SELECT count(*) FROM routine_participants rp JOIN profiles pp ON pp.id = rp.user_id
               WHERE rp.routine_id = ro.id AND rp.status = 'pending' AND NOT COALESCE(pp.can_lead, false)
                 AND pp.withdrawn_at IS NULL) AS w
        FROM routines ro
       WHERE ro.status = 'recruit' AND NOT COALESCE(ro.canceled, false) AND NOT COALESCE(ro.ongoing, false)
       ORDER BY ro.start_date NULLS LAST, ro.id
    LOOP
      n := n + 1;
      IF n <= 10 THEN
        v_x := v_x || '• ' || r.title || ' — '
               || CASE WHEN r.start_date IS NULL THEN '시작일 미정'
                       WHEN r.start_date < v_today THEN '시작일이 지났어요 (' || to_char(r.start_date, 'MM/DD') || ')'
                       WHEN r.start_date = v_today THEN '오늘 시작'
                       ELSE '시작 D-' || (r.start_date - v_today) || ' (' || to_char(r.start_date, 'MM/DD') || ')' END
               || ' · 신청 ' || r.p || '/' || COALESCE(r.max_people::text, '—') || '명'
               || CASE WHEN r.p < 3 AND r.start_date IS NOT NULL AND r.start_date <= v_today + 7 THEN ' ⚠️' ELSE '' END
               || CASE WHEN r.w > 0 THEN ' · 승인 대기 ' || r.w || '명' ELSE '' END || E'\n';
      END IF;
    END LOOP;
    IF n > 0 THEN
      v_out := v_out || E'\n*🌱 모집 중인 모임* ' || n || E'개 (시작이 7일 안인데 신청이 3명 미만이면 ⚠️)\n' || v_x
               || CASE WHEN n > 10 THEN '• … 외 ' || (n - 10) || E'개\n' ELSE '' END;
    END IF;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*🌱 모집 중인 모임*\n• (못 만들었어요)\n';
  END;

  -- 3-4. 매일 한끗(상시 모임) — 얼마나 쓰이나 (닉네임 없이 숫자만). 기존 모임 항목에서는 빠져 있다
  BEGIN
    j := ongoing_stats(v_y);
    IF j IS NOT NULL THEN
      v_out := v_out || E'\n*🌱 매일 한끗*\n'
        || '• 어제 ' || (j->>'did') || '/' || (j->>'people') || E'명 인증\n'
        || '• 연속 3일 이상 ' || (j->>'streak3') || '명 · 어제 연속이 끊긴 사람 ' || (j->>'broke') || E'명\n'
        || '• 어제 새로 참여 ' || (j->>'new_day') || '명 · 어제 응원 ' || (j->>'cheers_day') || E'건\n';
    END IF;
  EXCEPTION WHEN OTHERS THEN v_out := v_out || E'\n*🌱 매일 한끗*\n• (못 만들었어요)\n';
  END;

  -- 4. 처리할 것
  BEGIN
    v_out := v_out || E'\n*🛎️ 처리할 것*' || E'\n'
      || '• 청소년 확인 대기 ' || (SELECT count(*) FROM profiles WHERE verify_status = 'pending' AND withdrawn_at IS NULL) || E'건\n'
      || '• 끗짱 신청 대기 ' || (SELECT count(*) FROM kkut_applications WHERE status = 'pending') || E'건\n'
      || '• 열어달라는 모임 ' || (SELECT count(*) FROM routines WHERE status = 'pending') || E'건\n';
    -- 교환권이 있는데 청소년 확인이 안 된 사람 — 책을 못 받으니 확인부터 챙겨야 한다 (닉네임만)
    v_x := ''; n := 0;
    FOR r IN
      SELECT report_nick(a.user_id) AS nick FROM dokseo_points_all() a JOIN profiles p ON p.id = a.user_id
       WHERE p.withdrawn_at IS NULL AND a.remain > 0 AND COALESCE(p.verify_status, 'none') <> 'approved'
         AND COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
         AND NOT EXISTS (SELECT 1 FROM admin_user_ids() ad WHERE ad = p.id)
       ORDER BY 1
    LOOP
      n := n + 1; IF n <= 8 THEN v_x := v_x || r.nick || ', '; END IF;
    END LOOP;
    v_out := v_out || CASE WHEN n > 0 THEN '• ⚠️ *교환권이 있는데 청소년 확인 전* ' || n || '명 — ' || rtrim(v_x, ', ') || CASE WHEN n > 8 THEN ' 외' ELSE '' END || E'\n'
                           ELSE E'• 교환권이 있는데 청소년 확인 전인 사람 0명\n' END;
    -- 처리 안 된 인증 신고는 아이들 안전과 닿아 있다. 있으면 가장 오래된 것의 날수와 함께 눈에 띄게
    SELECT count(*), COALESCE(max(v_today - (created_at AT TIME ZONE 'Asia/Seoul')::date), 0) INTO n, v_a FROM cert_reports WHERE status = 'open';
    v_out := v_out || CASE WHEN n > 0 THEN '• ⚠️ *인증 신고 ' || n || '건 처리 안 됨* (가장 오래된 것 ' || v_a || E'일 전)\n'
                           ELSE E'• 인증 신고 0건\n' END;
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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 리포트 글이 그대로 나온다. 「🌱 모집 중인 모임」 줄에 신청 인원이 보이면 된다 (모집 중인 모임이 없으면 그 항목은 없다).
SELECT build_daily_report() AS 일일_리포트;
