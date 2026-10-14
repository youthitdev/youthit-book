-- 한끗독서 마이그레이션 127
-- 나다움 알림 둘 — 「공유회 다녀와서 나다움이 들어옴」 「교환권이 생김」 (2026-10-14 사용자)
--
-- 【안 보내는 것】 인증할 때마다 오는 적립 알림. 화면에 도장과 「+10N」이 뜨고, 하루에 한 번 더 울리면 정작 중요한 알림이 묻힌다.
--   「내가 모르는 사이에 들어온 나다움」과 「교환권이 생긴 순간」만 알린다.
--
-- ── A. 공유회 참석 ─────────────────────────────────────
--   끗짱이 참석을 표시(met_at 이 비어 있다가 채워짐)하는 순간 그 청소년에게 알림. 끗짱이 한참 뒤에 체크해도 그때 간다.
--   · 공유회가 걸린 루틴(meetup_required)일 때만 나다움이 붙으므로 그때만 보낸다
--   · 표시를 취소했다가 다시 하면 또 간다 (표시 자체가 새로 생기는 일이라서)
--
-- ── B. 교환권 ──────────────────────────────────────────
--   교환권은 나다움을 모은 숫자로 계산해서 보일 뿐 「생기는 순간」이 따로 없다. 인증·댓글·이정표·후기·공유회 어디서 늘어도
--   한 곳에서 잡으려고, 30분마다 사람별 교환권(earned)을 세어 **전에 알린 것보다 늘었으면** 알린다.
--   · 한 번 알린 장수는 voucher_notified 에 적어 둔다. 같은 알림이 두 번 가지 않는다
--   · 공유회를 놓쳐 나다움이 빠졌다 돌아오면 장수가 줄었다 다시 오른다 — 기록은 줄이지 않으니 이때는 다시 알리지 않는다
--   · 이 파일을 돌리는 순간 이미 있는 교환권은 기준으로만 적고 알리지 않는다 (처음에 한꺼번에 울리면 안 된다)
--   · 최대 30분 늦게 간다
--
-- 둘 다 끌 수 있는 종류가 아니다 (교환 관련이라 108 의 「끌 수 없는 알림」과 같다).
-- ⚠️ 40·68·71·76·108·123 뒤에 돌린다. 여러 번 돌려도 된다.

-- ── A. 공유회 참석 알림 ────────────────────────────────
CREATE OR REPLACE FUNCTION on_meetup_met() RETURNS trigger AS $$
DECLARE v_pts int; v_title text;
BEGIN
  IF NEW.met_at IS NULL OR OLD.met_at IS NOT NULL THEN RETURN NEW; END IF;   -- 표시가 새로 생길 때만

  SELECT r.title INTO v_title FROM routines r WHERE r.id = NEW.routine_id AND r.meetup_required;
  IF NOT FOUND THEN RETURN NEW; END IF;                                        -- 공유회 나다움이 없는 루틴
  IF EXISTS (SELECT 1 FROM profiles WHERE id = NEW.user_id AND (withdrawn_at IS NOT NULL OR COALESCE(role, 'youth') <> 'youth')) THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(points_per_meetup, 50) INTO v_pts FROM dokseo_settings WHERE id = 1;
  PERFORM notify_push(NEW.user_id, '공유회에 다녀오셨네요 🤝',
    COALESCE(v_title, '루틴') || ' · 나다움 +' || COALESCE(v_pts, 50) || 'N이 들어왔어요',
    '/youthit-book/app.html?tab=my');
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;      -- 알림 때문에 참석 표시가 막히면 안 된다
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS trg_on_meetup_met ON routine_participants;
CREATE TRIGGER trg_on_meetup_met
  AFTER UPDATE OF met_at ON routine_participants
  FOR EACH ROW EXECUTE FUNCTION on_meetup_met();

-- ── B. 교환권 알림 ────────────────────────────────────
CREATE TABLE IF NOT EXISTS voucher_notified (
  user_id uuid PRIMARY KEY,
  earned  int  NOT NULL DEFAULT 0,      -- 지금까지 알린 가장 큰 교환권 장수
  at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE voucher_notified ENABLE ROW LEVEL SECURITY;   -- 정책이 없으니 앱에서는 못 읽는다

CREATE OR REPLACE FUNCTION notify_new_vouchers() RETURNS int AS $$
DECLARE r record; n int := 0; v_old int;
BEGIN
  FOR r IN
    SELECT a.user_id, a.earned
      FROM dokseo_points_all() a
      JOIN profiles p ON p.id = a.user_id
     WHERE p.withdrawn_at IS NULL AND a.earned > 0
  LOOP
    SELECT earned INTO v_old FROM voucher_notified WHERE user_id = r.user_id;
    IF v_old IS NULL THEN v_old := 0; END IF;
    IF r.earned > v_old THEN
      PERFORM notify_push(r.user_id, '교환권이 생겼어요 🎫',
        '동네책방에서 책 한 권을 골라 바꿔 보세요', '/youthit-book/app.html?tab=store');
      INSERT INTO voucher_notified(user_id, earned) VALUES (r.user_id, r.earned)
        ON CONFLICT (user_id) DO UPDATE SET earned = EXCLUDED.earned, at = now();
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;
REVOKE EXECUTE ON FUNCTION notify_new_vouchers() FROM PUBLIC, anon, authenticated;

-- 지금 있는 교환권은 기준으로만 적는다 (알리지 않는다)
INSERT INTO voucher_notified(user_id, earned)
  SELECT a.user_id, a.earned FROM dokseo_points_all() a WHERE a.earned > 0
  ON CONFLICT (user_id) DO NOTHING;

SELECT cron.unschedule('dokseo-voucher-notify') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dokseo-voucher-notify');
SELECT cron.schedule('dokseo-voucher-notify', '7,37 * * * *', 'SELECT notify_new_vouchers()');

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 보내지 않는다. 기대: 방아쇠 1 / 함수 2 / 크론 1(켜짐) / 기준으로 적은 사람 수는 지금 교환권이 있는 사람 수
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_on_meetup_met')                        AS 방아쇠_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname IN ('on_meetup_met', 'notify_new_vouchers'))     AS 함수_2이어야,
       (SELECT count(*) FROM cron.job WHERE jobname = 'dokseo-voucher-notify' AND active)           AS 크론_1이어야,
       (SELECT count(*) FROM voucher_notified)                                                      AS 기준으로_적은_사람,
       (SELECT count(*) FROM dokseo_points_all() WHERE earned > 0)                                  AS 교환권_있는_사람,
       (SELECT count(*) FROM dokseo_points_all() a
          LEFT JOIN voucher_notified v ON v.user_id = a.user_id
         WHERE a.earned > COALESCE(v.earned, 0))                                                    AS 지금_알림_대기_0이어야;
