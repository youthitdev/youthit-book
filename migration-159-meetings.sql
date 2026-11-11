-- 한끗독서 마이그레이션 159
-- 루틴 만들기 개편 — 일정을 운영진이 미리 등록, 온라인 공유회, 루틴 주체, 최소 4명 자동 취소 (2026-11-11 요청)
--
-- 【무엇을】
--   1. routines 새 칸: host_kind(general/partner) · meetup_kind(online/offline) · schedule_id · online_meetup_id · min_people
--   2. meeting_schedules — 운영진이 미리 등록하는 루틴 일정(이름·시작일·종료일). 끗짱은 개설할 때 여기서 고른다.
--   3. online_meetups — 유스보이스가 정한 온라인 공유회 일시. online_meetup_links — Zoom 링크(운영진만 읽는다).
--      Zoom 링크는 meeting_zoom(루틴) 으로만 나간다: 그 루틴의 끗짱·승인된 참여자·운영진에게, 루틴이 열린 뒤에.
--   4. sync_routine_status(매일 0시 10분) — 시작일이 됐는데 최소 인원(min_people)에 못 미친 「모집 중」 루틴을 자동 폐강하고
--      참여자와 끗짱에게 알린다. min_people 가 있는 새 루틴만 대상이라, 이미 만들어진 루틴은 건드리지 않는다.
--   온라인 공유회는 책 교환 조건도 나다움 보너스도 없다(meetup_required 는 오프라인 공유회에서만 켜진다).
--
-- ⚠️ 134(sync_routine_status)·136(admin_cancel_routine) 뒤에 돌린다. 여러 번 돌려도 된다.

-- ── 1. 새 칸 ───────────────────────────────────────────
ALTER TABLE routines ADD COLUMN IF NOT EXISTS host_kind        text CHECK (host_kind IN ('general', 'partner'));
ALTER TABLE routines ADD COLUMN IF NOT EXISTS meetup_kind      text CHECK (meetup_kind IN ('online', 'offline'));
ALTER TABLE routines ADD COLUMN IF NOT EXISTS schedule_id      bigint;
ALTER TABLE routines ADD COLUMN IF NOT EXISTS online_meetup_id bigint;
ALTER TABLE routines ADD COLUMN IF NOT EXISTS min_people       int;

-- ── 2. 루틴 일정 ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS meeting_schedules (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  title      text NOT NULL,
  start_date date NOT NULL,
  end_date   date NOT NULL CHECK (end_date >= start_date),
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE meeting_schedules ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS msch_read ON meeting_schedules;
CREATE POLICY msch_read ON meeting_schedules FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS msch_admin ON meeting_schedules;
CREATE POLICY msch_admin ON meeting_schedules FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());

-- ── 3. 온라인 공유회 ───────────────────────────────────
CREATE TABLE IF NOT EXISTS online_meetups (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  at         timestamptz NOT NULL,
  label      text,
  active     boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE online_meetups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS omt_read ON online_meetups;
CREATE POLICY omt_read ON online_meetups FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS omt_admin ON online_meetups;
CREATE POLICY omt_admin ON online_meetups FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());

CREATE TABLE IF NOT EXISTS online_meetup_links (
  meetup_id bigint PRIMARY KEY REFERENCES online_meetups ON DELETE CASCADE,
  zoom_url  text NOT NULL
);
ALTER TABLE online_meetup_links ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS oml_admin ON online_meetup_links;
CREATE POLICY oml_admin ON online_meetup_links FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
-- 읽기 정책은 운영진뿐이다. 참여자는 아래 함수로만 받는다

CREATE OR REPLACE FUNCTION meeting_zoom(p_routine bigint) RETURNS text AS $$
DECLARE r routines; v_url text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  SELECT * INTO r FROM routines WHERE id = p_routine;
  IF NOT FOUND OR r.online_meetup_id IS NULL THEN RETURN NULL; END IF;
  IF NOT is_admin() AND r.led_by IS DISTINCT FROM auth.uid()
     AND NOT (r.status IN ('recruit', 'active') AND EXISTS (
           SELECT 1 FROM routine_participants rp
            WHERE rp.routine_id = r.id AND rp.user_id = auth.uid() AND rp.status = 'approved')) THEN
    RETURN NULL;
  END IF;
  -- 끗짱도 열리기 전에는 못 본다 (심사 중에는 링크가 나가지 않는다)
  IF NOT is_admin() AND r.status NOT IN ('recruit', 'active') THEN RETURN NULL; END IF;
  SELECT zoom_url INTO v_url FROM online_meetup_links WHERE meetup_id = r.online_meetup_id;
  RETURN v_url;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION meeting_zoom(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION meeting_zoom(bigint) TO authenticated;

-- ── 4. 최소 인원 미달 자동 폐강 ─────────────────────────
-- 134 의 함수에 맨 앞 단계만 더했다. 폐강 처리·참여자 알림은 136 의 admin_cancel_routine 을 그대로 쓴다
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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 새 칸 5 · 표 3 · 함수 1 · 자동 폐강이 들어간 상태함수 1
SELECT (SELECT count(*) FROM information_schema.columns WHERE table_name = 'routines'
         AND column_name IN ('host_kind', 'meetup_kind', 'schedule_id', 'online_meetup_id', 'min_people'))         AS 새칸_5이어야,
       (SELECT count(*) FROM information_schema.tables
         WHERE table_name IN ('meeting_schedules', 'online_meetups', 'online_meetup_links'))                        AS 표_3이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'meeting_zoom')                                                AS 줌함수_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'sync_routine_status' AND prosrc LIKE '%min_people%')          AS 자동폐강_1이어야;
