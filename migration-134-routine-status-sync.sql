-- 한끗독서 마이그레이션 134
-- 루틴 상태를 날짜에 맞춰 자동으로 바꾼다 — 시작일이 되면 「진행 중」, 종료일이 지나면 「완료」 (2026-10-14 사용자)
--
-- 【문제】 승인된 루틴은 「모집 중(recruit)」으로 올라가는데, 시작일이 되어도 「진행 중(active)」으로 바뀌지 않았고
--   「완료(done)」는 운영진이 직접 눌러야 했다. 그래서 이미 시작한 루틴(예: 책책책)도 관리자 통계에서 「모집 중」으로 보이고,
--   완주율은 끝난 루틴이 없으니 영영 나오지 않았다. 끗짱에게 가는 독서 리마인더(100)도 「진행 중」인 루틴만 보므로 안 갔다.
--
-- 【하는 일】 하루에 한 번(한국 시간 0시 10분) 서버가 아래를 처리하고, 이 파일을 돌릴 때도 한 번 처리한다.
--   · 시작일이 오늘이거나 지났고 아직 안 끝난 「모집 중」 루틴 → 「진행 중」
--   · 종료일이 어제까지인 「모집 중」·「진행 중」 루틴 → 「완료」
--   (심사 중(pending) 루틴과 이미 완료된 루틴은 건드리지 않는다)
--
-- 【앱에 미치는 영향】 앱은 이미 날짜로 판단한다(시작일이 지난 모집 중 루틴은 「이미 달리고 있다」, 종료일이 지나면 끝난 루틴).
--   그래서 화면이 크게 달라지지 않는다. 달라지는 것: ① 끗짱에게 가는 독서 리마인더가 시작된다 ② 「완료」가 되면 새 참여·인증이
--   막힌다(종료일이 지난 것과 같다) ③ 관리자 통계·루틴 목록의 상태가 실제와 맞는다.
--   상태를 바꿔도 알림은 가지 않는다 (끗짱 수정 알림·열림 알림은 다른 변화에만 반응한다).
--
-- ⚠️ 여러 번 돌려도 된다. 한국 시간 기준이라 크론은 UTC 15:10 에 돈다.

CREATE OR REPLACE FUNCTION sync_routine_status() RETURNS jsonb AS $$
DECLARE
  d date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  n_done int; n_active int;
BEGIN
  -- 끝난 것 먼저 (모집 중이었는데 시작도 전에 끝난 경우까지 한 번에)
  UPDATE routines SET status = 'done'
   WHERE status IN ('recruit', 'active') AND end_date IS NOT NULL AND end_date < d;
  GET DIAGNOSTICS n_done = ROW_COUNT;

  UPDATE routines SET status = 'active'
   WHERE status = 'recruit' AND start_date IS NOT NULL AND start_date <= d
     AND (end_date IS NULL OR end_date >= d);
  GET DIAGNOSTICS n_active = ROW_COUNT;

  RETURN jsonb_build_object('active', n_active, 'done', n_done);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION sync_routine_status() FROM PUBLIC, anon, authenticated;

-- 하루 한 번: 한국 시간 0시 10분 (= UTC 15:10)
SELECT cron.unschedule('dokseo-routine-status') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-routine-status');
SELECT cron.schedule('dokseo-routine-status', '10 15 * * *', 'SELECT sync_routine_status()');

-- 지금 한 번 처리한다
SELECT sync_routine_status() AS 이번에_바뀐_루틴;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 크론 1(켜짐) / 위 「이번에 바뀐 루틴」은 오늘 시작했거나 이미 끝난 루틴 수 / 아래는 루틴 상태별 수
SELECT (SELECT count(*) FROM cron.job WHERE jobname = 'dokseo-routine-status' AND active) AS 크론_1이어야,
       (SELECT count(*) FROM routines WHERE status = 'recruit') AS 모집_중,
       (SELECT count(*) FROM routines WHERE status = 'active')  AS 진행_중,
       (SELECT count(*) FROM routines WHERE status = 'done')    AS 완료,
       (SELECT count(*) FROM routines WHERE status = 'recruit' AND start_date <= (now() AT TIME ZONE 'Asia/Seoul')::date) AS 시작했는데_아직_모집중_0이어야;
