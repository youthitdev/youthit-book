-- 한끗독서 마이그레이션 68
-- 공유회 ① 「갈게요」 확인  ② 하루 전날 알림
--
-- 공유회에 와야 책을 받는 루틴인데, 아이가 그걸 읽었는지 알 길이 없었다.
-- 끗짱도 몇 명이 올지 모른 채 자리를 잡아야 했다.
--
-- 【met_at 과 다르다】 met_at 은 「왔다」를 끗짱이 표시하는 것이고,
--   meet_ack_at 은 「갈게요」를 본인이 누르는 것이다. 약속과 출석은 다르다.
--
-- 【안 눌러도 불이익 없다】 리워드 조건은 met_at 하나다. 체크는 서로
--   준비하자는 표시일 뿐, 안 눌렀다고 책을 못 받는 게 아니다.

ALTER TABLE routine_participants
  ADD COLUMN IF NOT EXISTS meet_ack_at timestamptz;
COMMENT ON COLUMN routine_participants.meet_ack_at IS '공유회에 「갈게요」를 본인이 누른 시각';

-- ── 본인만 누르고 본인만 되돌린다 ──────────────────────
-- routine_participants 의 UPDATE 는 끗짱·운영진에게만 열려 있다(parts_leader_update).
-- 그 문을 넓히는 대신, 이 칸 하나만 건드리는 길을 따로 낸다
CREATE OR REPLACE FUNCTION ack_meetup(p_routine_id bigint, p_ack boolean)
RETURNS timestamptz AS $$
DECLARE v_at timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;

  UPDATE routine_participants
     SET meet_ack_at = CASE WHEN p_ack THEN COALESCE(meet_ack_at, now()) ELSE NULL END
   WHERE routine_id = p_routine_id
     AND user_id    = auth.uid()
     AND status     = 'approved'
  RETURNING meet_ack_at INTO v_at;

  IF NOT FOUND THEN RAISE EXCEPTION '참여 중인 루틴이 아니에요'; END IF;
  RETURN v_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION ack_meetup(bigint, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION ack_meetup(bigint, boolean) TO authenticated;

-- ── 하루 전날 알림 ─────────────────────────────────────
-- 끗짱에게도 간다. 자리를 잡는 사람도 잊는다
CREATE OR REPLACE FUNCTION remind_meetup_tomorrow() RETURNS int AS $$
DECLARE
  n int := 0; r record;
  v_kst timestamp; v_h int; v_m int; v_when text; v_where text;
BEGIN
  FOR r IN
    SELECT u.user_id, ro.id AS rid, ro.title, ro.meetup_at,
           ro.meetup_place, ro.meetup_detail
      FROM routines ro
      JOIN LATERAL (
            SELECT rp.user_id FROM routine_participants rp
             WHERE rp.routine_id = ro.id AND rp.status = 'approved'
            UNION
            SELECT ro.led_by
           ) u ON true
     WHERE ro.meetup_required
       AND ro.meetup_at IS NOT NULL
       AND ro.status <> 'pending'
       AND (ro.meetup_at AT TIME ZONE 'Asia/Seoul')::date
           = ((now() AT TIME ZONE 'Asia/Seoul')::date + 1)
       AND u.user_id IS NOT NULL
  LOOP
    v_kst := r.meetup_at AT TIME ZONE 'Asia/Seoul';
    v_h := EXTRACT(hour   FROM v_kst)::int;
    v_m := EXTRACT(minute FROM v_kst)::int;
    v_when := CASE WHEN v_h < 12 THEN '오전 ' ELSE '오후 ' END
            || (CASE WHEN v_h % 12 = 0 THEN 12 ELSE v_h % 12 END)::text || '시'
            || CASE WHEN v_m > 0 THEN ' ' || v_m::text || '분' ELSE '' END;
    v_where := NULLIF(btrim(concat_ws(' ', r.meetup_place, r.meetup_detail)), '');

    PERFORM notify_push(r.user_id, '내일 공유회예요 🤝',
      COALESCE(r.title, '루틴') || ' · ' || v_when
        || COALESCE(' · ' || v_where, ''),
      '/youthit-book/app.html?routine=' || r.rid);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION remind_meetup_tomorrow() FROM PUBLIC, anon, authenticated;

-- ── 시계 ───────────────────────────────────────────────
-- cron 은 UTC 로 돈다. 10:30 KST = 01:30 UTC.
-- 후기 마감 알림(01:00)과 한 분이라도 떼어 둔다
SELECT cron.unschedule('dokseo-meetup-tomorrow')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-meetup-tomorrow');
SELECT cron.schedule('dokseo-meetup-tomorrow', '30 1 * * *', 'SELECT remind_meetup_tomorrow()');

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'routine_participants' AND column_name = 'meet_ack_at') AS 갈게요칸,
       (SELECT count(*) FROM pg_proc WHERE proname = 'ack_meetup')                  AS 누르기함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'remind_meetup_tomorrow')      AS 알림함수,
       (SELECT count(*) FROM cron.job WHERE jobname = 'dokseo-meetup-tomorrow')     AS 시계;
