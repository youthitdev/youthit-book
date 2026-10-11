-- 한끗독서 마이그레이션 119
-- 시작일 전에는 인증을 올릴 수 없게 서버가 막는다
--
-- 【증상】 15일에 시작하는 루틴인데, 11일에 인증을 올린 아이가 있다 (2026-10-11 사용자).
--   화면(app.html)은 시작 전 루틴의 「인증하기」를 숨기고 있다. 그런데 서버에는 막는 곳이 없어서,
--   예전 화면이 남아 있거나 알림·링크로 인증 창이 열리면 그대로 저장됐다.
--   (전에도 「시작 전에도 1일째로 보였다」는 같은 문제가 있었다)
--
-- 【고침】 인증을 새로 올릴 때 그 루틴의 시작일이 오늘(한국 시간)보다 뒤면 막는다.
--   · 운영진은 그대로 올릴 수 있다 (시험·정정용).
--   · 시작일이 없는 루틴은 막지 않는다.
--   · 고치기(UPDATE)는 막지 않는다 — 이미 있는 인증을 건드리지 않는다.
--   · 이미 올라간 시작 전 인증은 지우지 않는다. 아래 확인 목록으로 보고 운영진이 정한다.
--
-- ⚠️ 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION check_cert_started() RETURNS trigger AS $$
DECLARE v_start date;
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;
  SELECT start_date INTO v_start FROM routines WHERE id = NEW.routine_id;
  IF v_start IS NOT NULL AND v_start > (now() AT TIME ZONE 'Asia/Seoul')::date THEN
    RAISE EXCEPTION '아직 시작 전인 루틴이에요 (%월 %일 시작)', extract(month FROM v_start)::int, extract(day FROM v_start)::int;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS certs_started_only ON certifications;
CREATE TRIGGER certs_started_only BEFORE INSERT ON certifications
  FOR EACH ROW EXECUTE FUNCTION check_cert_started();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 1) 방아쇠가 붙었는지. 기대: 1
SELECT count(*) AS 방아쇠_1이어야 FROM pg_trigger WHERE tgname = 'certs_started_only' AND NOT tgisinternal;
-- 2) 이미 올라간 「시작 전 인증」. 아이 이름은 내지 않는다
SELECT r.id AS 루틴, r.title AS 이름, r.start_date AS 시작일, count(*) AS 시작전_인증,
       min((c.created_at AT TIME ZONE 'Asia/Seoul')::date) AS 가장_이른_인증일
  FROM certifications c JOIN routines r ON r.id = c.routine_id
 WHERE (c.created_at AT TIME ZONE 'Asia/Seoul')::date < r.start_date
 GROUP BY r.id, r.title, r.start_date
 ORDER BY r.start_date;
