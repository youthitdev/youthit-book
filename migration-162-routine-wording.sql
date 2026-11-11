-- 한끗독서 마이그레이션 162
-- 최소 인원 미달 자동 폐강 알림 문구를 「모임」에서 「루틴」으로 (2026-11-11 사용자: 이 서비스에서는 루틴이라고 부른다)
--
-- 【바뀌는 것】 159 의 sync_routine_status 에서 끗짱에게 보내는 알림 제목·본문의 낱말만 바꿔 다시 만든다. 동작은 같다.
-- ⚠️ 159 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION sync_routine_status() RETURNS jsonb AS $$
DECLARE
  d date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  n_done int; n_active int; n_cancel int := 0;
  x record;
BEGIN
  FOR x IN
    SELECT ro.id, ro.title, ro.led_by, ro.min_people
      FROM routines ro
     WHERE ro.status = 'recruit' AND NOT COALESCE(ro.canceled, false) AND NOT COALESCE(ro.ongoing, false)
       AND ro.min_people IS NOT NULL AND ro.start_date IS NOT NULL AND ro.start_date <= d
       AND (SELECT count(*) FROM routine_participants rp JOIN profiles pp ON pp.id = rp.user_id
             WHERE rp.routine_id = ro.id AND rp.status = 'approved' AND NOT COALESCE(pp.can_lead, false)) < ro.min_people
  LOOP
    PERFORM admin_cancel_routine(x.id);
    n_cancel := n_cancel + 1;
    IF x.led_by IS NOT NULL THEN
      BEGIN
        PERFORM notify_push(x.led_by, '루틴이 열리지 못했어요',
          COALESCE(x.title, '루틴') || ' · 최소 ' || x.min_people || '명이 모이지 않아 자동으로 취소됐어요',
          '/youthit-book/app.html?tab=home');
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;
  END LOOP;

  -- 끝난 것 먼저 (모집 중이었는데 시작도 전에 끝난 경우까지 한 번에)
  UPDATE routines SET status = 'done'
   WHERE status IN ('recruit', 'active') AND end_date IS NOT NULL AND end_date < d;
  GET DIAGNOSTICS n_done = ROW_COUNT;

  UPDATE routines SET status = 'active'
   WHERE status = 'recruit' AND start_date IS NOT NULL AND start_date <= d
     AND (end_date IS NULL OR end_date >= d);
  GET DIAGNOSTICS n_active = ROW_COUNT;

  RETURN jsonb_build_object('active', n_active, 'done', n_done, 'canceled', n_cancel);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION sync_routine_status() FROM PUBLIC, anon, authenticated;

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 1 (새 문구가 들어 있다)
SELECT count(*) AS 새문구_1이어야 FROM pg_proc WHERE proname = 'sync_routine_status' AND prosrc LIKE '%루틴이 열리지 못했어요%';
