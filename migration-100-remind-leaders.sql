-- 한끗독서 마이그레이션 100
-- 「오늘 한 장, 아직이에요」 알림을 끗짱에게도 보낸다
--
-- 【문제】 매일 독서 리마인더(remind_today_cert)는 routine_participants 에 있는 사람에게만 갔다.
--   끗짱은 자기 루틴의 참여자가 아니라서, **끗짱은 자기가 맡은 루틴의 오늘 인증 알림을 못 받았다.**
--   끗짱도 아이들과 같이 읽고 인증한다.
-- 【고친 것】 참여자(승인) 이거나 그 루틴의 끗짱(led_by)이면 대상이다. 나머지 조건은 그대로다:
--   리마인더를 켠 사람, 고른 시각이 지난 사람, 오늘 아직 안 보낸 사람, 진행 중인 루틴, 오늘 인증이 없는 사람.
-- ⚠️ 52 뒤에 돌린다. (알림은 이 함수를 크론이 30분마다 부를 때 나간다 — 확인용 SELECT 는 아무것도 보내지 않는다)

CREATE OR REPLACE FUNCTION remind_today_cert() RETURNS int AS $$
DECLARE
  n int := 0; r record;
  d date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  t time := (now() AT TIME ZONE 'Asia/Seoul')::time;
BEGIN
  FOR r IN
    SELECT DISTINCT p.id
      FROM profiles p
      JOIN routines ro
        ON ro.status = 'active'
       AND d BETWEEN ro.start_date AND ro.end_date
       AND ( ro.led_by = p.id
             OR EXISTS (SELECT 1 FROM routine_participants rp
                         WHERE rp.routine_id = ro.id AND rp.user_id = p.id AND rp.status = 'approved') )
     WHERE p.remind_on
       AND p.remind_at <= t                       -- 고른 시각이 지났고
       AND p.last_remind_on IS DISTINCT FROM d    -- 오늘 아직 안 보냈고
       AND NOT EXISTS (SELECT 1 FROM certifications c
                        WHERE c.routine_id = ro.id AND c.user_id = p.id
                          AND c.cert_date = d)
  LOOP
    -- 며칠 빠졌는지, 남들은 몇 명 했는지는 넣지 않는다
    PERFORM notify_push(r.id, '오늘 한 장, 아직이에요 📖',
      '한 장이면 오늘 몫은 끝이에요', '/youthit-book/app.html?tab=cert');
    UPDATE profiles SET last_remind_on = d WHERE id = r.id;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION remind_today_cert() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 보내지 않는다. 함수 몸통이 바뀌었는지, 같은 조건으로 지금 대상이 몇 명인지만 본다
SELECT (pg_get_functiondef('remind_today_cert'::regproc) LIKE '%ro.led_by = p.id%') AS 끗짱_포함됨,
       (SELECT count(DISTINCT p.id)
          FROM profiles p
          JOIN routines ro
            ON ro.status = 'active'
           AND (now() AT TIME ZONE 'Asia/Seoul')::date BETWEEN ro.start_date AND ro.end_date
           AND ( ro.led_by = p.id
                 OR EXISTS (SELECT 1 FROM routine_participants rp
                             WHERE rp.routine_id = ro.id AND rp.user_id = p.id AND rp.status = 'approved') )
         WHERE p.remind_on) AS 오늘_대상_후보;
