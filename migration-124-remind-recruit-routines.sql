-- 한끗독서 마이그레이션 124
-- 독서 리마인더가 「모집 중」 상태의 루틴에는 가지 않던 문제 (2026-10-12 테스트 제보)
--
-- 【제보】 「독서 리마인더 알림 설정한 시간이 지났음에도 리마인드 알림이 울리지 않음」 (모바일·청소년)
--
-- 【원인으로 보는 것】 리마인더 함수(remind_today_cert)가 **status = 'active' 인 루틴만** 대상으로 삼았다.
--   그런데 운영진이 승인한 루틴은 'recruit'(모집 중)이 되고, 시작일이 지나도 운영진이 손으로 「진행 중」으로 바꾸지 않으면
--   계속 'recruit' 로 남는다. 앱 화면은 상태가 아니라 **날짜**로 「N일째」를 세는데(승인 대기·종료만 뺀다),
--   리마인더만 상태를 따져서 **시작일이 지나 읽고 있는 아이들이 알림을 못 받았다.**
--
-- 【고침】 대상 루틴을 **status 가 recruit 또는 active 이고, 오늘이 시작일~종료일 안인 것**으로 넓힌다.
--   (승인 대기 pending 과 종료 done 은 그대로 뺀다.) 나머지 조건은 100 과 같다 —
--   리마인더를 켠 사람 · 고른 시각이 지난 사람 · 오늘 아직 안 보낸 사람 · 오늘 인증이 없는 사람, 참여자(승인) 또는 그 루틴의 끗짱.
--
-- 【알아 둘 것】 알림은 크론이 **30분마다** 이 함수를 부를 때 나간다. 8시 10분으로 정했으면 8시 30분 무렵에 한 번 간다.
--   푸시를 받으려면 그 폰에서 알림이 켜져 있어야 한다 (앱 안 알림함에는 상태와 관계없이 쌓인다).
--
-- ⚠️ 100 뒤에 돌린다. 여러 번 돌려도 된다. 아래 확인은 아무것도 보내지 않는다.

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
        ON ro.status IN ('recruit', 'active')
       AND d BETWEEN ro.start_date AND ro.end_date
       AND ( ro.led_by = p.id
             OR EXISTS (SELECT 1 FROM routine_participants rp
                         WHERE rp.routine_id = ro.id AND rp.user_id = p.id AND rp.status = 'approved') )
     WHERE p.remind_on
       AND p.withdrawn_at IS NULL                 -- 탈퇴 처리한 회원은 뺀다 (123)
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
-- 아무것도 보내지 않는다. 한 표로 본다.
--   · 크론: 「dokseo-today-cert」 가 있고 켜져 있어야 한다 (없으면 알림이 아예 안 나간다)
--   · 최근 실행: 오류가 있으면 그 문구가 보인다
--   · 오늘 날짜에 걸린 루틴을 상태별로 (recruit 가 많으면 위 원인이 맞다)
--   · 지금 같은 조건으로 알림 대상이 될 사람 수
SELECT '1 크론' AS 항목,
       COALESCE((SELECT schedule || ' · ' || CASE WHEN active THEN '켜짐' ELSE '꺼짐' END
                   FROM cron.job WHERE jobname = 'dokseo-today-cert' LIMIT 1), '없음 ⚠️') AS 내용
UNION ALL
SELECT '2 최근 실행', COALESCE((SELECT string_agg(to_char(start_time AT TIME ZONE 'Asia/Seoul', 'MM-DD HH24:MI') || ' ' || status
                                                   || CASE WHEN status <> 'succeeded' THEN ' ' || COALESCE(left(return_message, 60), '') ELSE '' END, ' / ' ORDER BY start_time DESC)
                                  FROM (SELECT d.* FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
                                         WHERE j.jobname = 'dokseo-today-cert' ORDER BY d.start_time DESC LIMIT 3) x), '실행 기록 없음')
UNION ALL
SELECT '3 오늘 걸린 루틴 · ' || status, count(*)::text
  FROM routines
 WHERE (now() AT TIME ZONE 'Asia/Seoul')::date BETWEEN start_date AND end_date
 GROUP BY status
UNION ALL
SELECT '4 알림 대상(지금)', count(DISTINCT p.id)::text
  FROM profiles p
  JOIN routines ro
    ON ro.status IN ('recruit', 'active')
   AND (now() AT TIME ZONE 'Asia/Seoul')::date BETWEEN ro.start_date AND ro.end_date
   AND ( ro.led_by = p.id
         OR EXISTS (SELECT 1 FROM routine_participants rp
                     WHERE rp.routine_id = ro.id AND rp.user_id = p.id AND rp.status = 'approved') )
 WHERE p.remind_on AND p.withdrawn_at IS NULL
ORDER BY 1;
