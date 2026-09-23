-- ────────────────────────────────────────────────────────────────────
-- 40. 자동으로 나가는 알림 두 가지
--
--   ① 후기 마감 하루 전 — 기한(7일)을 놓치면 30P 를 못 받는다.
--      기한을 둔 이유가 「빨리 쓰라」가 아니라 「잊지 말라」이므로 알려준다.
--   ② 저녁에 아직 오늘 인증이 없는 사람
--
--   ②는 조심해서 쓴다. 매일 「너 안 했다」를 보내면 뒤처진 아이가 앱을 지운다.
--   그래서 문구에 숫자도, 남과의 비교도 넣지 않는다. 하루에 한 번만 간다.
-- ────────────────────────────────────────────────────────────────────

-- 시계는 pg_cron 이 돌린다. Supabase 는 public 에 확장을 못 만들게 막아 두었다
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

-- ── 1. 후기 마감 하루 전 ───────────────────────────────
CREATE OR REPLACE FUNCTION remind_review_due() RETURNS int AS $$
DECLARE n int := 0; r record;
BEGIN
  FOR r IN
    SELECT rp.user_id, ro.id AS rid, ro.title, review_due(ro.id) AS due
      FROM routine_participants rp
      JOIN routines ro ON ro.id = rp.routine_id
     WHERE rp.status = 'approved'
       AND ro.status = 'done'
       AND review_due(ro.id) = ((now() AT TIME ZONE 'Asia/Seoul')::date + 1)
       AND NOT EXISTS (SELECT 1 FROM reviews v
                        WHERE v.routine_id = ro.id AND v.user_id = rp.user_id
                          AND v.kind = 'routine')
  LOOP
    PERFORM notify_push(r.user_id, '후기는 내일까지예요 ✍️',
      r.title || ' · 몇 줄이면 충분해요',
      '/youthit-book/app.html?tab=feed');
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION remind_review_due() FROM PUBLIC, anon, authenticated;

-- ── 2. 오늘 아직 인증이 없는 사람 ──────────────────────
CREATE OR REPLACE FUNCTION remind_today_cert() RETURNS int AS $$
DECLARE n int := 0; r record; d date := (now() AT TIME ZONE 'Asia/Seoul')::date;
BEGIN
  FOR r IN
    SELECT DISTINCT rp.user_id
      FROM routine_participants rp
      JOIN routines ro ON ro.id = rp.routine_id
     WHERE rp.status = 'approved'
       AND ro.status = 'active'
       AND d BETWEEN ro.start_date AND ro.end_date
       AND NOT EXISTS (SELECT 1 FROM certifications c
                        WHERE c.routine_id = ro.id AND c.user_id = rp.user_id
                          AND c.cert_date = d)
  LOOP
    -- 며칠 빠졌는지, 남들은 몇 명 했는지는 넣지 않는다
    PERFORM notify_push(r.user_id, '오늘 한 장, 아직이에요 📖',
      '한 장이면 오늘 몫은 끝이에요', '/youthit-book/app.html?tab=cert');
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION remind_today_cert() FROM PUBLIC, anon, authenticated;

-- ── 3. 시계 ────────────────────────────────────────────
-- cron 은 UTC 로 돈다. 10:00 KST = 01:00 UTC, 20:00 KST = 11:00 UTC
SELECT cron.unschedule('dokseo-review-due')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-review-due');
SELECT cron.unschedule('dokseo-today-cert')   WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-today-cert');
SELECT cron.schedule('dokseo-review-due', '0 1 * * *',  'SELECT remind_review_due()');
SELECT cron.schedule('dokseo-today-cert', '0 11 * * *', 'SELECT remind_today_cert()');

-- ── 확인 ───────────────────────────────────────────────
SELECT jobname AS 이름, schedule AS 시각, command AS 하는일, active AS 켜짐
  FROM cron.job WHERE jobname LIKE 'dokseo-%' ORDER BY 1;
